#!/bin/bash
# Uruchamiane raz po każdym udanym wdrożeniu (na pierwszym węźle WWW, jako www-data).
# Miejsce na zmiany w bazie, które mają iść razem z kodem: aktywacja wtyczek, motywu, ustawienia.
set -euo pipefail
wp() { /usr/local/bin/wp --path="$WP_PATH" "$@"; }

wp plugin activate lab-served-by
# Najnowszy domyślny motyw dołączony do WordPressa (twentytwentyfive, twentytwentysix …)
wp theme activate "$(wp theme list --field=name | grep '^twenty' | sort | tail -1)"

# Ćwiczenie ES: odkomentuj, zrób commit i push – wtyczka połączy się z Elasticsearch i zaindeksuje wpisy
# wp plugin activate elasticpress
# wp elasticpress sync --setup --yes

wp option update blogdescription "Lab: HAProxy + WordPress + Galera + Elasticsearch"
