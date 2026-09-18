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
# The server streams MPEG-TS, so save as .ts (a truncated .ts still plays).
OUTFILE="${OUTFILE:-$OUT_DIR/received.ts}"
PLAYER="${PLAYER:-auto}"    # live player: auto | ffplay | mpv | none

[ -f "$CLIENT_PY" ] || { echo "[client] FATAL: $CLIENT_PY not found (copy the whole repo to this machine)"; exit 1; }
[ -n "$SERVER_IP" ] || { echo "usage: $0 <server_ip>   (or set SERVER_IP=...)"; exit 1; }

mkdir -p "$OUT_DIR"
echo "[client] connecting to $SERVER_IP:$SERVER_PORT, saving to $OUTFILE (player=$PLAYER)"
export SERVER_IP SERVER_PORT OUTFILE PLAYER
python3 "$CLIENT_PY"; rc=$?

# Also produce a playable .mp4 from the saved .ts (works even if truncated).
case "$OUTFILE" in
  *.ts)
    if command -v ffmpeg >/dev/null 2>&1 && [ -s "$OUTFILE" ]; then
        MP4="${OUTFILE%.ts}.mp4"
        echo "[client] remuxing $OUTFILE -> $MP4 ..."
        ffmpeg -y -hide_banner -loglevel error -i "$OUTFILE" -c copy "$MP4" 2>/dev/null \
          || ffmpeg -y -hide_banner -loglevel error -i "$OUTFILE" -c:v libx264 -c:a aac "$MP4" 2>/dev/null \
          || echo "[client] (could not make .mp4; the .ts still plays)"
    fi
    ;;
esac
exit "$rc"
