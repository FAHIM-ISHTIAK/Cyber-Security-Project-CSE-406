#!/usr/bin/env python3
"""
arp_watch.py — Phase 2 ARP-poisoning DETECTOR / monitor (design proposal §6.2).

Static ARP entries (static_arp.sh / .ps1) PREVENT the attack; this tool DETECTS
it. Static pinning is "impractical at scale" (spec §6.2), so on real networks you
also want detection. arp_watch runs on a victim (or a dedicated defender host),
polls the OS neighbour/ARP table, and raises an alert the moment an ARP-poisoning
signature appears:

  * MAC CHANGE   — a watched IP's MAC suddenly changes (classic cache poisoning).
  * MITM COLLISION — two different watched IPs (e.g. server AND gateway) resolve
                     to the SAME MAC: the tell-tale sign of one host (the
                     attacker) impersonating several peers at once.

It is pure Python standard library (NO scapy, NO pip) and cross-platform
(Linux `ip neigh`, macOS/BSD `arp -an`, Windows `arp -a`), so it drops onto a
Windows or macOS client/server exactly as-is.

Optional active response (`--pin`): when a watched IP is poisoned and we know its
correct MAC (from a baseline or --expect), re-apply the correct static entry to
heal the cache automatically. This turns the monitor into a self-healing defense
for IPs you did not permanently pin. (Needs Admin/root; shells out to the OS.)

Usage:
  # Watch the server (and gateway); learn their real MACs at startup as baseline:
  python3 arp_watch.py --watch 192.168.1.10 --watch 192.168.1.1
  # Pin the expected MAC explicitly (most trustworthy — read it on the peer):
  python3 arp_watch.py --expect 192.168.1.10=aa:bb:cc:dd:ee:ff
  # Detect AND auto-heal (root/Admin):
  sudo python3 arp_watch.py --watch 192.168.1.10 --pin
"""
import argparse
import os
import platform
import re
import subprocess
import sys
import time
from datetime import datetime

IS_WIN = platform.system() == "Windows"
IS_MAC = platform.system() == "Darwin"
IS_LINUX = platform.system() == "Linux"

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

MAC_RE = re.compile(r"([0-9a-fA-F]{2}(?:[:-][0-9a-fA-F]{2}){5})")
IP_RE = re.compile(r"\b(\d{1,3}(?:\.\d{1,3}){3})\b")


def norm_mac(mac: str) -> str:
    return mac.lower().replace("-", ":") if mac else ""


def read_arp_table() -> dict:
    """Return {ip: mac} from the OS neighbour/ARP table (all lowercase colon)."""
    table = {}
    try:
        if IS_LINUX:
            out = subprocess.check_output(["ip", "neigh", "show"], text=True, stderr=subprocess.DEVNULL)
            for line in out.splitlines():
                parts = line.split()
                if len(parts) >= 5 and "lladdr" in parts:
                    ip = parts[0]
                    mac = parts[parts.index("lladdr") + 1]
                    table[ip] = norm_mac(mac)
        elif IS_MAC:
            out = subprocess.check_output(["arp", "-an"], text=True, stderr=subprocess.DEVNULL)
            for line in out.splitlines():          # ? (192.168.1.10) at aa:bb:.. on en0 ...
                ipm = re.search(r"\(([\d.]+)\)", line)
                macm = MAC_RE.search(line)
                if ipm and macm and "incomplete" not in line:
                    table[ipm.group(1)] = norm_mac(macm.group(1))
        else:  # Windows
            out = subprocess.check_output(["arp", "-a"], text=True, stderr=subprocess.DEVNULL)
            for line in out.splitlines():          #   192.168.1.10   aa-bb-cc-dd-ee-ff  dynamic
                ipm = IP_RE.search(line)
                macm = MAC_RE.search(line)
                if ipm and macm:
                    table[ipm.group(1)] = norm_mac(macm.group(1))
    except Exception as e:
        print(f"[watch] WARNING: could not read ARP table: {e}", flush=True)
    return table


def solicit(ip: str) -> None:
    """Force the OS to (re)resolve an IP so it appears in the table."""
    try:
        if IS_WIN:
            subprocess.run(["ping", "-n", "1", "-w", "800", ip],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            flag = "-t" if IS_MAC else "-W"
            subprocess.run(["ping", "-c", "1", flag, "1", ip],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def repin(ip: str, mac: str) -> bool:
    """Re-apply the correct static entry (active response). Needs root/Admin."""
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        if IS_WIN:
            ps = os.path.join(here, "static_arp.ps1")
            subprocess.run(["powershell", "-ExecutionPolicy", "Bypass", "-File", ps, "pin", ip, mac],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            sh = os.path.join(here, "static_arp.sh")
            subprocess.run(["bash", sh, "pin", ip, mac],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except Exception as e:
        print(f"[watch] auto-heal FAILED for {ip} ({e}). Run static_arp as root/Admin.", flush=True)
        return False


def ts() -> str:
    return datetime.now().strftime("%H:%M:%S")


def alert(msg: str, logf) -> None:
    line = f"[watch] {ts()}  !!! {msg}"
    print("\a" + line, flush=True)          # \a = terminal bell
    if logf:
        logf.write(line + "\n"); logf.flush()


def main() -> int:
    ap = argparse.ArgumentParser(description="ARP-poisoning detector / monitor")
    ap.add_argument("--watch", action="append", default=[], metavar="IP",
                    help="IP to monitor; baseline MAC learned at startup (repeatable)")
    ap.add_argument("--expect", action="append", default=[], metavar="IP=MAC",
                    help="IP with its KNOWN-GOOD MAC (repeatable; most trustworthy)")
    ap.add_argument("--interval", type=float, default=1.0, help="poll seconds (default 1)")
    ap.add_argument("--pin", action="store_true",
                    help="auto-heal: re-apply the correct static entry on poisoning (root/Admin)")
    ap.add_argument("--log", default="", help="also append alerts to this file")
    args = ap.parse_args()

    expected = {}
    for item in args.expect:
        if "=" not in item:
            print(f"[watch] bad --expect '{item}', want IP=MAC", file=sys.stderr); return 1
        ip, mac = item.split("=", 1)
        expected[ip.strip()] = norm_mac(mac.strip())

    watch_ips = list(dict.fromkeys(args.watch + list(expected.keys())))
    if not watch_ips:
        print("[watch] nothing to watch. Pass --watch <ip> and/or --expect <ip>=<mac>.", file=sys.stderr)
        return 1

    logf = open(args.log, "a", encoding="utf-8") if args.log else None

    # Establish the baseline: prefer --expect; else learn the current MAC now.
    # Learning at startup assumes you start the monitor BEFORE the attacker.
    print(f"[watch] platform={platform.system()} watching {', '.join(watch_ips)} "
          f"every {args.interval}s  auto-heal={'ON' if args.pin else 'off'}", flush=True)
    for ip in watch_ips:
        if ip not in expected:
            solicit(ip)
    time.sleep(0.4)
    table = read_arp_table()
    baseline = {}
    for ip in watch_ips:
        mac = expected.get(ip) or table.get(ip, "")
        if mac:
            baseline[ip] = mac
            src = "expected" if ip in expected else "learned"
            print(f"[watch] baseline {ip} -> {mac} ({src})", flush=True)
        else:
            print(f"[watch] baseline {ip} -> (unresolved; will learn when it appears)", flush=True)

    print("[watch] monitoring ... (Ctrl+C to stop)", flush=True)
    healthy_since = time.time()
    try:
        while True:
            table = read_arp_table()

            # (1) per-IP MAC-change / mismatch detection
            for ip in watch_ips:
                cur = table.get(ip, "")
                if not cur:
                    continue
                good = baseline.get(ip)
                if good is None:                       # first time we see it -> baseline it
                    baseline[ip] = cur
                    print(f"[watch] {ts()}  learned {ip} -> {cur}", flush=True)
                    continue
                if cur != good:
                    alert(f"ARP POISONING on {ip}: MAC changed {good} -> {cur}", logf)
                    healthy_since = time.time()
                    if args.pin and repin(ip, good):
                        print(f"[watch] {ts()}  auto-healed {ip} -> {good} (static)", flush=True)

            # (2) MITM collision: two watched IPs sharing one MAC = one impostor
            seen = {}
            for ip in watch_ips:
                cur = table.get(ip, "")
                if cur:
                    seen.setdefault(cur, []).append(ip)
            for mac, ips in seen.items():
                if len(ips) > 1:
                    alert(f"MITM SIGNATURE: {mac} is claiming multiple IPs {ips} "
                          f"(one host impersonating several peers)", logf)
                    healthy_since = time.time()

            # occasional heartbeat so a quiet run visibly proves it's watching
            if time.time() - healthy_since > 15:
                print(f"[watch] {ts()}  OK — no poisoning; "
                      f"{ {ip: baseline.get(ip,'?') for ip in watch_ips} }", flush=True)
                healthy_since = time.time()

            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("\n[watch] stopped.", flush=True)
    finally:
        if logf:
            logf.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
