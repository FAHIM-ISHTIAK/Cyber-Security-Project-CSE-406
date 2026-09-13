#!/usr/bin/env bash
# static_arp.sh — ARP-layer defense demo (design proposal Section 6.2).
#
# Pinning a static IP->MAC entry makes a host ignore the attacker's forged ARP
# replies, so the MITM never forms. With no MITM the attacker cannot read the
# live sequence number and the attack collapses to the far harder blind case.
#
# Run INSIDE the victim client container, giving it the server's REAL MAC:
#
#   1) find the server's real MAC (run in the attacker or server container):
#        cat /sys/class/net/eth0/address        # on streamserver
#      or from the client BEFORE poisoning:
#        ip neigh show 172.20.0.10
#
#   2) pin it on the client (needs NET_ADMIN; run in the client container):
#        ./static_arp.sh add 172.20.0.10 <server_mac>
#
#   3) re-run the attack: ARP poisoning no longer redirects the client, the
#      injector never sees the flow, and playback continues uninterrupted.
#
#   4) undo:  ./static_arp.sh del 172.20.0.10
set -euo pipefail

action="${1:-}"; ip="${2:-}"; mac="${3:-}"; iface="${IFACE:-eth0}"

case "$action" in
  add)
    [ -n "$ip" ] && [ -n "$mac" ] || { echo "usage: $0 add <ip> <mac>"; exit 1; }
    ip neigh replace "$ip" lladdr "$mac" nud permanent dev "$iface"
    echo "[defense] pinned $ip -> $mac (PERMANENT) on $iface"
    ip neigh show "$ip"
    ;;
  del)
    [ -n "$ip" ] || { echo "usage: $0 del <ip>"; exit 1; }
    ip neigh del "$ip" dev "$iface" || true
    echo "[defense] removed static entry for $ip on $iface"
    ;;
  show)
    ip neigh show
    ;;
  *)
    echo "usage: $0 {add <ip> <mac>|del <ip>|show}"; exit 1
    ;;
esac
