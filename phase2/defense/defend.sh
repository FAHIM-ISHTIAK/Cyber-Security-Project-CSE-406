#!/usr/bin/env bash
# defend.sh — Phase 2 one-shot defense driver for a LINUX/macOS victim (§6.2).
#
# Ties the two ARP-layer defenses together for a single victim machine:
#   1) PREVENT — pin the peer's real IP->MAC as a permanent/static entry so forged
#      ARP replies are ignored and the MITM never forms (static_arp.sh pin).
#   2) DETECT  — run the arp_watch.py monitor so any poisoning attempt (or an
#      attempt on an un-pinned host like the gateway) is flagged immediately.
#
# Run on the CLIENT (pin the SERVER) and, ideally, on the SERVER (pin the CLIENT).
# Do this BEFORE launching the attacker, so the learned MACs are the real ones.
# Best practice: read the peer's real MAC on the peer itself and pass --peer-mac.
#
# Usage:
#   sudo ./defend.sh --peer <peer_ip> [--peer-mac <mac>] [--gateway <gw_ip>]
#                    [--watch] [--pin-watch] [--no-pin]
#     --peer       the machine to protect against being spoofed (server IP on the
#                  client; client IP on the server). REQUIRED.
#     --peer-mac   the peer's real MAC (skip auto-learn; most trustworthy).
#     --gateway    also pin+watch the default gateway (recommended).
#     --watch      after pinning, run the arp_watch monitor in the foreground.
#     --pin-watch  like --watch but auto-heals (re-pins) on detection.
#     --no-pin     detection only: skip static pinning, just run arp_watch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATIC="$SCRIPT_DIR/static_arp.sh"
WATCH="$SCRIPT_DIR/arp_watch.py"
PY="$(command -v python3 || command -v python)"

PEER=""; PEER_MAC=""; GATEWAY=""; DO_WATCH=0; PIN_WATCH=0; DO_PIN=1; OFF=0
while [ $# -gt 0 ]; do
    case "$1" in
        --peer) PEER="$2"; shift 2;;
        --peer-mac) PEER_MAC="$2"; shift 2;;
        --gateway) GATEWAY="$2"; shift 2;;
        --watch) DO_WATCH=1; shift;;
        --pin-watch) DO_WATCH=1; PIN_WATCH=1; shift;;
        --no-pin) DO_PIN=0; shift;;
        --off) OFF=1; shift;;
        *) echo "unknown arg: $1"; exit 1;;
    esac
done
[ -n "$PEER" ] || { echo "usage: sudo $0 --peer <ip> [--peer-mac <mac>] [--gateway <ip>] [--watch|--pin-watch] [--no-pin] [--off]"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "[defense] run as root: sudo $0 ..."; exit 1; }

# Auto-detect the gateway if the user asked to protect it without giving the IP.
if [ "$GATEWAY" = "auto" ]; then
    GATEWAY="$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')"
    [ -n "$GATEWAY" ] && echo "[defense] auto-detected gateway: $GATEWAY"
fi

# --off: turn the defense OFF again (remove the static entries) so you can show
# the attack succeeding once more. Stop any running monitor with Ctrl+C separately.
if [ "$OFF" -eq 1 ]; then
    echo "[defense] === turning defense OFF on this host: unpinning peer=$PEER ${GATEWAY:+gateway=$GATEWAY} ==="
    bash "$STATIC" unpin "$PEER"
    [ -n "$GATEWAY" ] && bash "$STATIC" unpin "$GATEWAY"
    echo "[defense] static entries removed; ARP is dynamic again. (Ctrl+C the arp_watch monitor if it is running.)"
    exit 0
fi

EXPECT_ARGS=()

pin_one() {  # ip [mac]
    local ip="$1" mac="${2:-}"
    if [ "$DO_PIN" -eq 1 ]; then
        if [ -n "$mac" ]; then bash "$STATIC" pin "$ip" "$mac"; else bash "$STATIC" pin "$ip"; fi
    fi
    # Whatever is now cached (freshly pinned, or current) becomes the watch baseline.
    local cur; cur="$(bash "$STATIC" verify "$ip" 2>/dev/null | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -n1 || true)"
    [ -n "$cur" ] && EXPECT_ARGS+=(--expect "$ip=$cur")
}

echo "[defense] === protecting this host: peer=$PEER ${GATEWAY:+gateway=$GATEWAY} pin=$([ $DO_PIN -eq 1 ] && echo yes || echo no) ==="
pin_one "$PEER" "$PEER_MAC"
[ -n "$GATEWAY" ] && pin_one "$GATEWAY"

if [ "$DO_WATCH" -eq 1 ]; then
    echo "[defense] starting ARP monitor (Ctrl+C to stop) ..."
    if [ "$PIN_WATCH" -eq 1 ]; then
        exec "$PY" "$WATCH" "${EXPECT_ARGS[@]}" --pin
    else
        exec "$PY" "$WATCH" "${EXPECT_ARGS[@]}"
    fi
else
    echo "[defense] static entries in place. Verify with: bash $STATIC show"
    echo "[defense] to also monitor: sudo $PY $WATCH ${EXPECT_ARGS[*]}"
fi
