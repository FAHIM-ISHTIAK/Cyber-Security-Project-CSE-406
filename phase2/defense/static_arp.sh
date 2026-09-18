#!/usr/bin/env bash
# static_arp.sh — Phase 2 ARP-layer defense for a LINUX or macOS victim
# (design proposal §6.2). Run on the CLIENT and/or the SERVER machine.
#
# The attack only works because ARP poisoning puts the attacker on-path so it can
# read the live TCP sequence numbers. Pinning a peer's real IP->MAC mapping as a
# PERMANENT/static entry makes this host ignore the attacker's forged ARP replies,
# so the MITM never forms and the attack collapses to the far-harder blind case.
#
# Unlike the top-level defense/static_arp.sh (Phase 1 / Docker, hardcoded eth0 +
# 172.20.0.x), this one auto-detects the LAN interface, works on Linux AND macOS,
# and can LEARN the peer's real MAC for you (do this BEFORE the attacker starts).
#
# Usage:
#   sudo ./static_arp.sh pin   <peer_ip> [peer_mac]   # learn (or use given) MAC, pin it
#   sudo ./static_arp.sh unpin <peer_ip>              # remove the static entry
#   ./static_arp.sh show                              # print the neighbour table
#   ./static_arp.sh verify <peer_ip> [peer_mac]       # is peer_ip pinned (to peer_mac)?
#
# Typical: on the CLIENT, pin the SERVER's IP; on the SERVER, pin the CLIENT's IP.
# Pinning the gateway too is good practice: sudo ./static_arp.sh pin <gateway_ip>
set -euo pipefail

OS="$(uname -s)"
IFACE="${IFACE:-}"

die() { echo "[defense] ERROR: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "must run as root: sudo $0 $*"; }

# --- interface auto-detection (the iface used to reach an IP) ------------------
detect_iface() {
    local ip="$1"
    if [ -n "$IFACE" ]; then echo "$IFACE"; return; fi
    case "$OS" in
        Linux)  ip -o route get "$ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}';;
        Darwin) route -n get "$ip" 2>/dev/null | awk '/interface:/{print $2; exit}';;
    esac
}

# --- MAC helpers: normalise to lowercase colon form ---------------------------
norm_mac() { echo "$1" | tr 'A-Z' 'a-z' | tr '-' ':'; }

# Read the currently-cached MAC for an IP from the OS neighbour table.
cached_mac() {
    local ip="$1"
    case "$OS" in
        Linux)  ip neigh show "$ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="lladdr"){print $(i+1); exit}}';;
        Darwin) arp -n "$ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="at"){print $(i+1); exit}}' | grep -v incomplete || true;;
    esac
}

# Learn a peer's real MAC by soliciting it (ping to force ARP), then reading the
# neighbour table. MUST be done BEFORE the attacker poisons, or the learned value
# will already be the attacker's MAC. Prefer passing the MAC explicitly (read it
# ON the peer machine) when you can.
learn_mac() {
    local ip="$1" iface="$2" mac=""
    case "$OS" in
        Linux)  ping -c1 -W1 -I "$iface" "$ip" >/dev/null 2>&1 || true;;
        Darwin) ping -c1 -t1 "$ip" >/dev/null 2>&1 || true;;
    esac
    mac="$(cached_mac "$ip")"
    echo "$mac"
}

pin() {
    local ip="$1" mac="${2:-}"
    [ -n "$ip" ] || die "usage: $0 pin <peer_ip> [peer_mac]"
    need_root "pin" "$ip" "$mac"
    local iface; iface="$(detect_iface "$ip")"
    [ -n "$iface" ] || die "could not determine interface to reach $ip (set IFACE=...)"

    if [ -z "$mac" ]; then
        echo "[defense] no MAC given; learning $ip's real MAC on $iface (do this BEFORE the attack) ..."
        mac="$(learn_mac "$ip" "$iface")"
        [ -n "$mac" ] || die "could not learn MAC for $ip. Is it up and on the same LAN? Or pass it explicitly: $0 pin $ip <mac>"
        echo "[defense] learned $ip -> $mac"
    fi
    mac="$(norm_mac "$mac")"

    case "$OS" in
        Linux)  ip neigh replace "$ip" lladdr "$mac" nud permanent dev "$iface";;
        Darwin) arp -s "$ip" "$mac";;   # macOS 'arp -s' entries are permanent
    esac
    echo "[defense] PINNED $ip -> $mac (permanent) on $iface"
    echo "[defense] forged ARP replies for $ip will now be IGNORED by this host."
    verify "$ip" "$mac" || true
}

unpin() {
    local ip="$1"
    [ -n "$ip" ] || die "usage: $0 unpin <peer_ip>"
    need_root "unpin" "$ip"
    local iface; iface="$(detect_iface "$ip")"
    case "$OS" in
        Linux)  ip neigh del "$ip" dev "${iface:-$(detect_iface "$ip")}" 2>/dev/null || true;;
        Darwin) arp -d "$ip" 2>/dev/null || true;;
    esac
    echo "[defense] removed static entry for $ip (ARP resolution reverts to dynamic)"
}

show() {
    case "$OS" in
        Linux)  ip neigh show;;
        Darwin) arp -an;;
    esac
}

# Exit 0 if ip is present and (when mac given) matches; else non-zero.
verify() {
    local ip="$1" want="${2:-}"
    local have; have="$(norm_mac "$(cached_mac "$ip")")"
    if [ -z "$have" ]; then echo "[defense] verify: $ip has NO entry"; return 2; fi
    if [ -n "$want" ]; then
        want="$(norm_mac "$want")"
        if [ "$have" = "$want" ]; then
            echo "[defense] verify: OK  $ip -> $have (matches expected)"; return 0
        else
            echo "[defense] verify: !! $ip -> $have  BUT expected $want  (POSSIBLE POISONING)"; return 1
        fi
    fi
    echo "[defense] verify: $ip -> $have"; return 0
}

case "${1:-}" in
    pin)    shift; pin "${1:-}" "${2:-}";;
    unpin)  shift; unpin "${1:-}";;
    show)   show;;
    verify) shift; verify "${1:-}" "${2:-}";;
    *) echo "usage: $0 {pin <ip> [mac] | unpin <ip> | show | verify <ip> [mac]}"; exit 1;;
esac
