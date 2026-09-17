#!/usr/bin/env bash
# run_server.sh — Phase 2 (physical) launcher for the video server.
#
# Runs the SAME server code as Phase 1 (server/stream_server.py) natively on a
# real machine, no Docker. Binds 0.0.0.0:9000 so the client (over Wi-Fi/LAN)
# can connect. If no media file exists it bakes a 120s test video with ffmpeg,
# exactly like the Phase 1 image did.
#
# Usage:
#   ./run_server.sh                 # generate/serve phase2/media/sample.mp4
#   MEDIA=/path/to/video.mp4 ./run_server.sh
#   PORT=9000 STREAM_SECONDS=120 ./run_server.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SERVER_PY="$REPO_ROOT/server/stream_server.py"
MEDIA_DIR="$REPO_ROOT/phase2/media"

PORT="${PORT:-9000}"
STREAM_SECONDS="${STREAM_SECONDS:-120}"
MEDIA="${MEDIA:-$MEDIA_DIR/sample.mp4}"

[ -f "$SERVER_PY" ] || { echo "[server] FATAL: $SERVER_PY not found (copy the whole repo to this machine)"; exit 1; }

# Ensure a media file exists; generate a test-pattern video if ffmpeg is present.
if [ ! -f "$MEDIA" ]; then
    if command -v ffmpeg >/dev/null 2>&1; then
        echo "[server] no media file; generating a 120s test video at $MEDIA ..."
        mkdir -p "$(dirname "$MEDIA")"
        ffmpeg -hide_banner -loglevel error \
            -f lavfi -i testsrc=size=640x360:rate=25:duration=120 \
            -f lavfi -i sine=frequency=1000:duration=120 \
            -c:v libx264 -preset veryfast -pix_fmt yuv420p \
            -c:a aac -shortest "$MEDIA"
    else
        echo "[server] FATAL: media file $MEDIA missing and ffmpeg not installed."
        echo "[server]        Install ffmpeg, or set MEDIA=/path/to/your/video.mp4"
        exit 1
    fi
fi

echo "[server] ------------------------------------------------------------"
echo "[server] This machine's LAN IPv4 address(es) — tell the CLIENT & ATTACKER:"
if command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show scope global | awk '{print "    " $2 "  " $4}'
elif command -v ifconfig >/dev/null 2>&1; then
    ifconfig | awk '/inet /{print "    " $2}'
fi
echo "[server] Serving $MEDIA on 0.0.0.0:$PORT (Ctrl+C to stop)"
echo "[server] macOS/Linux firewall: allow inbound TCP $PORT if the client cannot connect."
echo "[server] ------------------------------------------------------------"

export BIND_ADDR="0.0.0.0" PORT MEDIA STREAM_SECONDS
exec python3 "$SERVER_PY"
