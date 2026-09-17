#!/usr/bin/env bash
# setup.sh — install the attacker's tooling into a Python virtualenv (Phase 2).
#
# The attacker MUST be Linux: ARP spoofing and RST injection use raw sockets,
# scapy, and /proc/sys/net/ipv4/ip_forward, none of which exist natively on
# Windows/macOS. Run this once on the native Linux attacker (Ubuntu/Mint/Kali).
#
# We install the ONE third-party Python package we need (scapy) into a local
# virtualenv at phase2/attacker/venv, and the system libraries scapy relies on
# (libpcap via tcpdump) with apt. Run this WITHOUT sudo — it uses sudo only for
# the apt step, so the venv stays owned by your user.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$SCRIPT_DIR/venv"

if [ "$(id -u)" -eq 0 ]; then
    echo "[setup] run WITHOUT sudo (it will call sudo only for apt): ./setup.sh"
    exit 1
fi

if command -v apt-get >/dev/null 2>&1; then
    echo "[setup] installing system packages (needs your sudo password) ..."
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends \
        python3 python3-venv python3-pip tcpdump iproute2 iputils-ping net-tools dsniff
else
    echo "[setup] non-apt system: install python3, python3-venv, tcpdump, iproute2"
    echo "[setup] with your package manager, then re-run this script."
fi

echo "[setup] creating virtualenv at $VENV ..."
python3 -m venv "$VENV"
"$VENV/bin/pip" install --upgrade pip >/dev/null
"$VENV/bin/pip" install scapy

echo "[setup] verifying scapy in the venv ..."
"$VENV/bin/python" -c "import scapy; print('[setup] scapy', scapy.__version__, 'OK in venv')"

echo "[setup] done. Next:"
echo "  sudo ./preflight.sh --server <SERVER_IP> --client <CLIENT_IP>"
