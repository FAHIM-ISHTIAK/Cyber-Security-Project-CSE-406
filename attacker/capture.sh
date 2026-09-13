#!/usr/bin/env bash
# capture.sh — capture the victim connection to a pcap for Wireshark analysis.
# The resulting file shows the injected RST directly after a run of DATA
# segments with NO preceding FIN/FIN-ACK (design proposal Section 5, "On the wire").
#
# Usage: ./capture.sh [outfile.pcap]
set -euo pipefail
SERVER_IP="${SERVER_IP:-172.20.0.10}"
CLIENT_IP="${CLIENT_IP:-172.20.0.20}"
SERVER_PORT="${SERVER_PORT:-9000}"
IFACE="${IFACE:-eth0}"
OUT="${1:-/out/capture.pcap}"

echo "[capture] writing $OUT (Ctrl+C to stop) ..."
tcpdump -i "$IFACE" -w "$OUT" \
    "tcp and host $SERVER_IP and host $CLIENT_IP and port $SERVER_PORT"
