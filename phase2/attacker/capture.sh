#!/usr/bin/env bash
# capture.sh — capture the victim connection to a pcap for Wireshark (Phase 2).
# Shows the injected RST right after a run of DATA segments with NO preceding
# FIN/FIN-ACK (spec §5, "On the wire").
#
# Usage: sudo ./capture.sh --server <ip> --client <ip> [-i iface] [--port 9000] [-o file.pcap]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER=""; CLIENT=""; IFACE=""; PORT="9000"; OUT="$SCRIPT_DIR/../output/phase2_capture.pcap"
while [ $# -gt 0 ]; do
    case "$1" in
        --server) SERVER="$2"; shift 2;;
        --client) CLIENT="$2"; shift 2;;
        -i|--iface) IFACE="$2"; shift 2;;
        --port) PORT="$2"; shift 2;;
        -o|--out) OUT="$2"; shift 2;;
        *) echo "unknown arg: $1"; exit 1;;
    esac
done
[ -n "$SERVER" ] && [ -n "$CLIENT" ] || { echo "usage: sudo $0 --server <ip> --client <ip> [-i iface] [--port 9000] [-o file.pcap]"; exit 1; }
[ -z "$IFACE" ] && IFACE="$(ip -o route get "$SERVER" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
mkdir -p "$(dirname "$OUT")"
echo "[capture] iface=$IFACE writing $OUT (Ctrl+C to stop) ..."
exec tcpdump -i "$IFACE" -w "$OUT" "tcp and host $SERVER and host $CLIENT and port $PORT"
