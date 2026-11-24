#!/bin/bash
# Wdrożenie kroczące (rolling): węzły po kolei, po każdym test. Gdy test nie przejdzie,
# węzeł wraca do poprzedniego wydania, a wdrożenie się zatrzymuje – drugi węzeł dalej obsługuje ruch.
# Użycie (jako deploy na VPS3): wp-deploy <commit|gałąź>   np. wp-deploy main
set -euo pipefail

# shellcheck source=/dev/null
. /etc/wp-lab/lab.env

rev="${1:?Podaj commit lub gałąź}"
if [ "$(id -un)" != "deploy" ]; then
  exec sudo -u deploy "$0" "$@"
fi

echo "=== Wdrożenie ${rev:0:12} na: $WEB_NODES ==="
# shellcheck disable=SC2029  # $rev ma się rozwinąć lokalnie i trafić na zdalny węzeł
for host in $WEB_NODES; do
  echo "--> $host: budowa wydania"
  if ! ssh "$host" sudo /usr/local/sbin/wp-release "$rev"; then
    echo "!!! $host: budowa wydania nie powiodła się – przerywam (stare wydanie dalej działa)"
    exit 1
  fi
  echo "--> $host: test po wdrożeniu"
  if ! ssh "$host" /usr/local/bin/wp-smoke-test; then
    echo "!!! $host: test NIE przeszedł – cofam ten węzeł i przerywam wdrożenie"
    ssh "$host" sudo /usr/local/sbin/wp-rollback
    echo "!!! Popraw kod i zrób kolejny commit (np. git revert HEAD && git push)"
    exit 1
  fi
  echo "--> $host: OK"
done

first=${WEB_NODES%% *}
echo "--> $first: zadania po wdrożeniu (aktualizacja bazy, wtyczki – deploy/post-deploy.sh)"
ssh "$first" sudo /usr/local/sbin/wp-post-deploy
echo "=== Wdrożenie zakończone ==="
