#!/usr/bin/env bash
# setup.sh — install the attacker's tooling inside the Linux VM (Phase 2).
#
# The attacker MUST be Linux: ARP spoofing and RST injection use raw sockets,
# scapy, and /proc/sys/net/ipv4/ip_forward, none of which exist natively on
# Windows/macOS. Run this once in the Linux VM (Kali/Ubuntu/Debian).
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo ./setup.sh"; exit 1; }

if command -v apt-get >/dev/null 2>&1; then
    echo "[setup] apt-based system detected; installing tooling ..."
    apt-get update
    apt-get install -y --no-install-recommends \
        python3 python3-pip python3-scapy dsniff tcpdump iproute2 iputils-ping net-tools
    # Fallback if the distro package for scapy is missing/old.
    python3 -c "import scapy" 2>/dev/null || pip3 install --break-system-packages scapy
else
    echo "[setup] non-apt system: install python3, scapy, dsniff, tcpdump via your"
    echo "[setup] package manager, then:  pip3 install scapy"
fi

echo "[setup] done. Verify with: ./preflight.sh --server <ip> --client <ip>"
