#!/usr/bin/env bash
# run_client.sh — Phase 2 (physical) launcher for the victim video client.
#
# Runs the SAME client code as Phase 1 (client/stream_client.py) natively on a
# real machine, no Docker. Connects over the LAN/Wi-Fi to the server's real IP.
#
# Usage:
#   ./run_client.sh 192.168.1.10            # server IP as first arg
#   SERVER_IP=192.168.1.10 ./run_client.sh
#   RECONNECT=1 ./run_client.sh 192.168.1.10   # measure auto-retry (spec §5)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLIENT_PY="$REPO_ROOT/client/stream_client.py"
OUT_DIR="$REPO_ROOT/phase2/output"

SERVER_IP="${1:-${SERVER_IP:-}}"
SERVER_PORT="${SERVER_PORT:-9000}"
OUTFILE="${OUTFILE:-$OUT_DIR/received.mp4}"

[ -f "$CLIENT_PY" ] || { echo "[client] FATAL: $CLIENT_PY not found (copy the whole repo to this machine)"; exit 1; }
[ -n "$SERVER_IP" ] || { echo "usage: $0 <server_ip>   (or set SERVER_IP=...)"; exit 1; }

mkdir -p "$OUT_DIR"
echo "[client] connecting to $SERVER_IP:$SERVER_PORT, saving to $OUTFILE"
export SERVER_IP SERVER_PORT OUTFILE
exec python3 "$CLIENT_PY"
