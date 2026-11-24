#!/bin/bash
# Buduje nowe wydanie WordPressa z repozytorium Git i atomowo przełącza na nie symlink "current".
# Uruchamiane przez wp-deploy z VPS3 albo ręcznie:  sudo wp-release main   |   sudo wp-release <commit>
#
# Wydanie = rdzeń WordPressa w wersji z pliku .wp-version + kod z repozytorium (wp-content/)
#           + wtyczki z plugins.txt + wspólny wp-config.php + symlink uploads -> S3.
set -euo pipefail

# shellcheck source=/dev/null
. /etc/wp-lab/lab.env

rev="${1:-main}"
cache=/var/cache/wp-lab

# 1. Ustalenie commita (dla gałęzi pytamy repozytorium, commit podany wprost zostawiamy)
sha=$(sudo -u deploy git ls-remote "$GIT_REPO_URL" "$rev" | awk 'NR==1 {print $1}')
sha=${sha:-$rev}
rel="$WP_BASE/releases/$(date +%Y%m%d-%H%M%S)-${sha:0:7}"
echo "[$LAB_NODE] wydanie $(basename "$rel")"

trap 'echo "[$LAB_NODE] BŁĄD – usuwam niedokończone wydanie"; rm -rf "$rel"' ERR
mkdir -p "$rel"

# 2. Kod strony z Git (bez historii – tylko pliki z danego commita)
sudo -u deploy git archive --remote="$GIT_REPO_URL" --format=tar "$sha" | tar -x -C "$rel"

# 3. Rdzeń WordPressa (pobierany raz na wersję, potem z pamięci podręcznej)
wp_ver=$(tr -d '[:space:]' < "$rel/.wp-version" 2>/dev/null || true)
if [ -z "$wp_ver" ] || [ "$wp_ver" = "latest" ]; then
  # shellcheck disable=SC2016  # kod PHP w apostrofach celowo
  wp_ver=$(curl -fsS https://api.wordpress.org/core/version-check/1.7/ \
    | php -r '$j = json_decode(stream_get_contents(STDIN), true); echo $j["offers"][0]["current"];')
fi
core="$cache/core-$wp_ver-$WP_LOCALE"
if [ ! -f "$core/wp-load.php" ]; then
  echo "[$LAB_NODE] pobieram WordPress $wp_ver ($WP_LOCALE)"
  rm -rf "$core.tmp"
  if ! wp core download --version="$wp_ver" --locale="$WP_LOCALE" --path="$core.tmp" --allow-root --quiet; then
    echo "[$LAB_NODE] brak paczki $WP_LOCALE dla $wp_ver – pobieram wersję angielską"
    rm -rf "$core.tmp"
    wp core download --version="$wp_ver" --path="$core.tmp" --allow-root --quiet
  fi
  mv "$core.tmp" "$core"
fi
# Pliki z repozytorium mają pierwszeństwo przed plikami z paczki WordPressa
cp -a --update=none "$core/." "$rel/"

# 4. Wtyczki z wordpress.org wg plugins.txt ("nazwa [wersja]")
if [ -f "$rel/plugins.txt" ]; then
  grep -vE '^[[:space:]]*(#|$)' "$rel/plugins.txt" | while read -r slug ver; do
    zip="$cache/plugin-$slug${ver:+.$ver}.zip"
    if [ ! -f "$zip" ]; then
      echo "[$LAB_NODE] pobieram wtyczkę $slug ${ver:-najnowsza}"
      curl -fsSL -o "$zip.tmp" "https://downloads.wordpress.org/plugin/$slug${ver:+.$ver}.zip"
      mv "$zip.tmp" "$zip"
    fi
    unzip -qo "$zip" -d "$rel/wp-content/plugins/"
  done
fi

# 5. Konfiguracja i pliki wspólne
cp "$WP_BASE/shared/wp-config.php" "$rel/wp-config.php"
rm -rf "$rel/wp-content/uploads"
ln -s "$WP_BASE/shared/uploads" "$rel/wp-content/uploads"
echo "$sha" > "$rel/REVISION"
chown -R root:www-data "$rel"
chmod -R u=rwX,g=rX,o= "$rel"
trap - ERR

# 6. Przełączenie (atomowe: nowy symlink + rename) i przeładowanie PHP (czyści OPcache)
ln -sfn "$rel" "$WP_BASE/current.new"
mv -T "$WP_BASE/current.new" "$WP_BASE/current"
php_ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
systemctl reload "php$php_ver-fpm"
echo "[$LAB_NODE] aktywne wydanie: $(basename "$rel") (WordPress $wp_ver)"

# 7. Sprzątanie – zostaje 5 najnowszych wydań
find "$WP_BASE/releases" -mindepth 1 -maxdepth 1 -type d | sort | head -n -5 | xargs -r rm -rf
