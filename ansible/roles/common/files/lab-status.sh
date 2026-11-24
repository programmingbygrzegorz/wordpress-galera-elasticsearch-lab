#!/bin/bash
# Szybki przegląd stanu labu z dowolnej maszyny: usługi lokalne + stan klastrów.
# Użycie: lab-status
set -uo pipefail

# shellcheck source=/dev/null
. /etc/wp-lab/lab.env

ok()   { printf '  \e[32m✔\e[0m %s\n' "$*"; }
bad()  { printf '  \e[31m✘\e[0m %s\n' "$*"; }
info() { printf '\n\e[1m== %s ==\e[0m\n' "$*"; }

info "Maszyna $LAB_NODE ($LAB_NODE_IP)"
for svc in haproxy nginx php8.4-fpm mariadb elasticsearch seaweedfs zabbix-server zabbix-agent2 postgresql; do
  systemctl list-unit-files "$svc.service" >/dev/null 2>&1 || continue
  systemctl cat "$svc" >/dev/null 2>&1 || continue
  if systemctl is-active --quiet "$svc"; then ok "$svc działa"; else bad "$svc NIE działa"; fi
done

if command -v mariadb >/dev/null; then
  info "MariaDB Galera"
  mariadb -N -e "SHOW STATUS WHERE Variable_name IN
    ('wsrep_cluster_size','wsrep_cluster_status','wsrep_local_state_comment','wsrep_ready','wsrep_incoming_addresses')" 2>/dev/null \
    | awk '{printf "  %-28s %s\n", $1, $2}' || bad "brak połączenia z MariaDB"
fi

if [ "$LAB_NODE" != "lb" ]; then
  info "Elasticsearch"
  curl -s -m 5 "http://127.0.0.1:9200/_cluster/health?pretty" \
    | grep -E '"(status|number_of_nodes|active_shards|unassigned_shards)"' || bad "Elasticsearch nie odpowiada"
fi

if mountpoint -q "$WP_BASE/shared/uploads" 2>/dev/null; then
  info "S3 (s3fs)"
  if timeout 5 ls "$WP_BASE/shared/uploads" >/dev/null 2>&1; then
    ok "uploads zamontowany i czytelny ($(timeout 5 find "$WP_BASE/shared/uploads" -type f 2>/dev/null | wc -l) plików)"
  else
    bad "uploads zamontowany, ale nie odpowiada (S3 na VPS3 działa?)"
  fi
elif [ -d "$WP_BASE" ]; then
  info "S3 (s3fs)"; bad "uploads NIE jest zamontowany"
fi

if [ -L "$WP_BASE/current" ]; then
  info "WordPress"
  rel=$(readlink -f "$WP_BASE/current")
  ok "aktualne wydanie: $(basename "$rel") (commit $(cat "$rel/REVISION" 2>/dev/null))"
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1/healthz)
  if [ "$code" = 200 ]; then ok "healthz: 200"; else bad "healthz: $code"; fi
fi

if [ "$LAB_NODE" = "lb" ]; then
  info "HAProxy – stan backendów"
  echo "show stat" | socat stdio /run/haproxy/admin.sock 2>/dev/null \
    | awk -F, '$1 ~ /^be_/ && $2 !~ /BACKEND/ {printf "  %-12s %-6s %s\n", $1, $2, $18}'
fi
echo
