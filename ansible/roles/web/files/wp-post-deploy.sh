#!/bin/bash
# Zadania jednorazowe po wdrożeniu (baza jest wspólna, więc tylko na jednym węźle):
# instalacja WordPressa przy pierwszym uruchomieniu, aktualizacja bazy, skrypt deploy/post-deploy.sh z repozytorium.
set -euo pipefail

# shellcheck source=/dev/null
. /etc/wp-lab/lab.env

wp() { sudo -u www-data HOME=/tmp WP_CLI_CACHE_DIR=/tmp/wp-cli-cache /usr/local/bin/wp --path="$WP_BASE/current" "$@"; }

if ! wp core is-installed 2>/dev/null; then
  wp core install --url="https://$WP_DOMAIN" --title="WordPress Lab" \
    --admin_user=admin --admin_password="$(cat /etc/wp-lab/wp-admin.pass)" \
    --admin_email="admin@$WP_DOMAIN" --skip-email
  echo "Zainstalowano WordPress (użytkownik admin, hasło w .lab/wp_admin_password)"
fi

wp core update-db

hook="$WP_BASE/current/deploy/post-deploy.sh"
if [ -f "$hook" ]; then
  echo "Uruchamiam deploy/post-deploy.sh z repozytorium"
  sudo -u www-data HOME=/tmp WP_CLI_CACHE_DIR=/tmp/wp-cli-cache WP_PATH="$WP_BASE/current" bash "$hook"
fi
