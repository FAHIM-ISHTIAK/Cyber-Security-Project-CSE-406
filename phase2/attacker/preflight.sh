#!/usr/bin/env bash
# preflight.sh — verify the Linux VM attacker is ready BEFORE attacking (Phase 2).
#
# Physical/Wi-Fi demos fail for boring reasons: the VM is on NAT instead of
# bridged, the AP has client isolation on, or the interface name is wrong. This
# script catches those up front and prints the exact iface/IP/MAC values.
#
# Usage:
#   sudo ./preflight.sh --server 192.168.1.10 --client 192.168.1.20 [-i wlan0]
set -euo pipefail

SERVER=""; CLIENT=""; IFACE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --server) SERVER="$2"; shift 2;;
        --client) CLIENT="$2"; shift 2;;
        -i|--iface) IFACE="$2"; shift 2;;
        *) echo "unknown arg: $1"; exit 1;;
    esac
done
[ -n "$SERVER" ] && [ -n "$CLIENT" ] || { echo "usage: sudo $0 --server <ip> --client <ip> [-i iface]"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0 ..."; exit 1; }

fail=0
note() { printf '  [%s] %s\n' "$1" "$2"; }

echo "== Tooling =="
for t in python3 tcpdump ip arpspoof; do
    if command -v "$t" >/dev/null 2>&1; then note OK "$t present"; else note "!!" "$t MISSING (run ./setup.sh)"; fail=1; fi
done
if python3 -c "import scapy" 2>/dev/null; then note OK "python scapy importable"; else note "!!" "scapy MISSING (run ./setup.sh)"; fail=1; fi

echo "== Interface =="
# Auto-detect the interface that reaches the server if not given.
if [ -z "$IFACE" ]; then
    IFACE="$(ip -o route get "$SERVER" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
fi
[ -n "$IFACE" ] || { note "!!" "could not determine interface to reach $SERVER"; exit 1; }
MYIP="$(ip -o route get "$SERVER" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
MYMAC="$(cat "/sys/class/net/$IFACE/address" 2>/dev/null || echo '?')"
note OK "iface=$IFACE  my_ip=$MYIP  my_mac=$MYMAC"

# Same-subnet sanity check: attacker, server, client must share the L2 segment.
pfx="$(ip -o -f inet addr show dev "$IFACE" | awk '{print $4}' | head -n1)"
note OK "my subnet on $IFACE = $pfx"
case "$MYIP" in
    10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|192.168.*) ;;
    169.254.*) note "!!" "APIPA/link-local IP ($MYIP) => VM has NO real LAN address. Bridged networking is not working (likely on NAT, or Wi-Fi bridge failed). See README 'Attacker networking'."; fail=1;;
    "") note "!!" "no source IP on $IFACE"; fail=1;;
esac

echo "== Reachability & MAC resolution (needs client isolation OFF on the AP) =="
for pair in "server $SERVER" "client $CLIENT"; do
    role="${pair%% *}"; ip="${pair##* }"
    if ping -c1 -W2 -I "$IFACE" "$ip" >/dev/null 2>&1; then
        mac="$(ip neigh show "$ip" dev "$IFACE" | awk '{print $3}' | head -n1)"
        if [ -n "$mac" ]; then note OK "$role $ip reachable, mac=$mac"; else note "!!" "$role $ip pings but no MAC learned"; fi
    else
        note "!!" "$role $ip UNREACHABLE. On Wi-Fi this usually means AP CLIENT ISOLATION is ON (or wrong IP). Disable AP/client isolation on the router, or use a test router/travel AP you control."
        fail=1
    fi
done

echo "== IP forwarding =="
fwd="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
if [ "$fwd" = "1" ]; then note OK "ip_forward already on"; else note ".." "ip_forward off (run_attack.sh will enable it so the stream keeps flowing)"; fi

echo
if [ "$fail" -eq 0 ]; then
    echo "PREFLIGHT PASSED. Attack with:"
    echo "  sudo ./run_attack.sh --server $SERVER --client $CLIENT -i $IFACE"
else
    echo "PREFLIGHT FOUND PROBLEMS (see [!!] lines above). Fix them before attacking."
    exit 1
fi
