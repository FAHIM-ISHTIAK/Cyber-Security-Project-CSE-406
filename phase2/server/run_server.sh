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

[ -f "$SERVER_PY" ] || { echo "[server] FATAL: $SERVER_PY not found (copy the whole repo to this machine)"; exit 1; }

# We stream MPEG-TS (.ts): it plays progressively in a live player and a
# truncated copy (cut by the RST) still plays up to the cut. The launcher
# prepares phase2/media/sample.ts from whatever source is available:
#   MEDIA=... override  ->  use it (.ts as-is, other containers remuxed to .ts)
#   phase2/media/sample.ts exists  ->  stream it
#   phase2/media/sample.mp4 exists ->  remux it to .ts (keeps the "drop an mp4" workflow)
#   otherwise                      ->  generate a 120s .ts test clip with ffmpeg
MEDIA_MP4="$MEDIA_DIR/sample.mp4"
MEDIA_TS="$MEDIA_DIR/sample.ts"
mkdir -p "$MEDIA_DIR"

remux_to_ts() {  # $1=input  $2=output.ts  (stream-copy, fall back to re-encode)
    ffmpeg -y -hide_banner -loglevel error -i "$1" \
        -c copy -bsf:v h264_mp4toannexb -f mpegts "$2" 2>/dev/null \
    || ffmpeg -y -hide_banner -loglevel error -i "$1" \
        -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -f mpegts "$2"
}

if [ -n "${MEDIA:-}" ]; then
    [ -f "$MEDIA" ] || { echo "[server] FATAL: MEDIA=$MEDIA set but file not found"; exit 1; }
    case "$MEDIA" in
        *.ts) echo "[server] using MEDIA override (already MPEG-TS): $MEDIA" ;;
        *)    command -v ffmpeg >/dev/null 2>&1 || { echo "[server] FATAL: need ffmpeg to convert $MEDIA to MPEG-TS"; exit 1; }
              echo "[server] converting MEDIA override $MEDIA to MPEG-TS ..."
              remux_to_ts "$MEDIA" "$MEDIA_TS"; MEDIA="$MEDIA_TS" ;;
    esac
elif [ -f "$MEDIA_TS" ]; then
    MEDIA="$MEDIA_TS"; echo "[server] streaming existing $MEDIA_TS"
elif [ -f "$MEDIA_MP4" ] && command -v ffmpeg >/dev/null 2>&1; then
    echo "[server] remuxing existing sample.mp4 to MPEG-TS ..."
    remux_to_ts "$MEDIA_MP4" "$MEDIA_TS"; MEDIA="$MEDIA_TS"
elif command -v ffmpeg >/dev/null 2>&1; then
    echo "[server] generating a 120s MPEG-TS test video at $MEDIA_TS ..."
    ffmpeg -y -hide_banner -loglevel error \
        -f lavfi -i testsrc=size=640x360:rate=25:duration=120 \
        -f lavfi -i sine=frequency=1000:duration=120 \
        -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac \
        -f mpegts "$MEDIA_TS"
    MEDIA="$MEDIA_TS"
else
    MB="${MEDIA_MB:-8}"
    echo "[server] ffmpeg not found; generating a ${MB} MB placeholder (NOT playable - install ffmpeg for real video)"
    head -c "$((MB * 1024 * 1024))" /dev/urandom > "$MEDIA_TS"
    MEDIA="$MEDIA_TS"
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
