#!/bin/bash
# Kontrolowane awarie do ćwiczeń. Uruchamiaj na maszynie, którą chcesz „zepsuć”.
#   sudo lab-chaos slow  [sekundy] [opóźnienie_ms]  – opóźnienie sieci labu (domyślnie 60 s, 6000 ms)
#   sudo lab-chaos flap  [minuty]                   – co jakiś czas krótkie zawieszenie strony („mrugające” alerty)
#   sudo lab-chaos stop  <usługa>                   – zatrzymanie usługi (nginx, mariadb, elasticsearch, seaweedfs …)
#   sudo lab-chaos isolate [sekundy]                – odcięcie maszyny od reszty labu (split-brain w Galerze)
#   sudo lab-chaos clear                            – usunięcie opóźnień i blokad sieci
set -euo pipefail

# shellcheck source=/dev/null
. /etc/wp-lab/lab.env

[ "$(id -u)" -eq 0 ] || { echo "Uruchom przez sudo"; exit 1; }

iface=$(ip -o -4 addr show | awk -v ip="$LAB_NODE_IP" '{split($4, a, "/"); if (a[1] == ip) print $2}')
[ -n "$iface" ] || { echo "Nie znalazłem interfejsu z adresem $LAB_NODE_IP"; exit 1; }

clear_net() {
  tc qdisc del dev "$iface" root 2>/dev/null || true
  iptables -D INPUT -i "$iface" -j DROP 2>/dev/null || true
  iptables -D OUTPUT -o "$iface" -j DROP 2>/dev/null || true
}

case "${1:-}" in
  slow)
    secs=${2:-60}; delay=${3:-6000}
    echo "Opóźnienie ${delay} ms na $iface przez ${secs} s"
    tc qdisc replace dev "$iface" root netem delay "${delay}ms"
    sleep "$secs"; clear_net; echo "Koniec opóźnienia"
    ;;
  flap)
    mins=${2:-10}; end=$(( $(date +%s) + mins * 60 ))
    echo "Przez $mins min co 1-4 min strona zawiesza się na 20-90 s (Ctrl+C przerywa)"
    trap 'clear_net; exit' INT TERM
    while [ "$(date +%s)" -lt "$end" ]; do
      sleep $(( 60 + RANDOM % 180 ))
      hang=$(( 20 + RANDOM % 70 ))
      echo "$(date +%T) zawieszenie na ${hang} s"
      tc qdisc replace dev "$iface" root netem delay 15000ms
      sleep "$hang"; clear_net
    done
    ;;
  stop)
    svc=${2:?Podaj usługę, np. nginx}
    systemctl stop "$svc"; echo "$svc zatrzymany. Przywrócenie: sudo systemctl start $svc"
    ;;
  isolate)
    secs=${2:-120}
    command -v iptables >/dev/null || apt-get install -y -q iptables >/dev/null
    echo "Odcinam $LAB_NODE od sieci labu na ${secs} s (SSH przez vagrant ssh dalej działa)"
    iptables -I INPUT -i "$iface" -j DROP
    iptables -I OUTPUT -o "$iface" -j DROP
    sleep "$secs"; clear_net; echo "Sieć przywrócona"
    ;;
  clear)
    clear_net; echo "Wyczyszczono"
    ;;
  *)
    sed -n '2,8p' "$0"; exit 1
    ;;
esac
