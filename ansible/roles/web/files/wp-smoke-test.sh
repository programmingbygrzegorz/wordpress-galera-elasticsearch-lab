#!/bin/bash
# Test po wdrożeniu na tym węźle: health check + strona główna + logowanie (bez przechodzenia przez LB).
set -uo pipefail

# shellcheck source=/dev/null
. /etc/wp-lab/lab.env

fail=0
check() {
  local path=$1 expect=$2 code
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 \
    -H "Host: $WP_DOMAIN" -H "X-Forwarded-Proto: https" "http://127.0.0.1$path")
  if [ "$code" = "$expect" ]; then
    echo "  OK   $path -> $code"
  else
    echo "  BŁĄD $path -> $code (oczekiwano $expect)"; fail=1
  fi
}

echo "[$LAB_NODE] test strony"
check /healthz 200
check / 200
check /wp-login.php 200
exit $fail
