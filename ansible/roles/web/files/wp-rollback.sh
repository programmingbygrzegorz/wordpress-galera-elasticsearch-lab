#!/bin/bash
# Szybki powrót do poprzedniego wydania na TYM węźle (bez Gita).
# Uwaga: to „gaszenie pożaru” – trwała poprawka to git revert + push.
set -euo pipefail

# shellcheck source=/dev/null
. /etc/wp-lab/lab.env

current=$(readlink -f "$WP_BASE/current")
mapfile -t releases < <(find "$WP_BASE/releases" -mindepth 1 -maxdepth 1 -type d | sort)

prev=""
for r in "${releases[@]}"; do
  [ "$r" = "$current" ] && break
  prev="$r"
done
[ -n "$prev" ] || { echo "[$LAB_NODE] brak wcześniejszego wydania"; exit 1; }

ln -sfn "$prev" "$WP_BASE/current.new"
mv -T "$WP_BASE/current.new" "$WP_BASE/current"
php_ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
systemctl reload "php$php_ver-fpm"
echo "[$LAB_NODE] cofnięto: $(basename "$current") -> $(basename "$prev")"
