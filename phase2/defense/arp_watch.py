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

IMPORTANT — detecting the attack WHILE a static pin blocks it. Table polling
cannot see the attack once you have pinned a static ARP entry, because the OS
table then never changes (the forged replies are ignored before they reach it).
For that case use `--sniff` (Linux, root): it reads ARP frames straight off the
wire and flags a forged reply even while the pin silently blocks it. `defend.sh`
turns this on automatically.

Usage:
  # Watch the server (and gateway); learn their real MACs at startup as baseline:
  python3 arp_watch.py --watch 192.168.1.10 --watch 192.168.1.1
  # Pin the expected MAC explicitly (most trustworthy — read it on the peer):
  python3 arp_watch.py --expect 192.168.1.10=aa:bb:cc:dd:ee:ff
  # SEE the attack even while statically pinned (Linux, root) — wire detection:
  sudo python3 arp_watch.py --expect 192.168.1.10=aa:bb:cc:dd:ee:ff --sniff
  # Detect AND auto-heal (root/Admin):
  sudo python3 arp_watch.py --watch 192.168.1.10 --pin
"""
import argparse
import os
import platform
import re
import socket
import struct
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


ETH_P_ARP = 0x0806


def sniff_wire(watch_ips, good_map, iface, logf, do_pin) -> bool:
    """Detect forged ARP on the WIRE (Linux, root).

    Table polling (the default loop below) cannot see the attack once a static
    pin is in place, because the OS neighbour table never changes — the forged
    replies are ignored before they reach it. This mode instead reads incoming
    ARP frames straight off the NIC, so it flags a forged reply that claims a
    watched IP with the wrong MAC EVEN WHILE the static pin silently blocks it.

    Returns False (so the caller falls back to table polling) if it can't run
    here (non-Linux, no root, or nothing with a known-good MAC). Otherwise it
    blocks until Ctrl+C.
    """
    if not IS_LINUX or not hasattr(socket, "AF_PACKET"):
        print("[watch] --sniff (wire detection) needs Linux. On Windows/macOS the "
              "static pin still BLOCKS the attack, but silently; run the monitor on "
              "the Linux victim to SEE the detection. Falling back to table polling.",
              flush=True)
        return False
    watchset = {ip for ip in watch_ips if good_map.get(ip)}
    if not watchset:
        print("[watch] --sniff: no watched IP has a known-good MAC to compare against; "
              "falling back to table polling.", flush=True)
        return False
    try:
        s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ARP))
        if iface:
            s.bind((iface, socket.htons(ETH_P_ARP)))
    except PermissionError:
        print("[watch] --sniff needs root (raw socket). Re-run with sudo. "
              "Falling back to table polling.", flush=True)
        return False
    except OSError as e:
        print(f"[watch] --sniff could not open a raw socket ({e}); "
              f"falling back to table polling.", flush=True)
        return False
    s.settimeout(1.0)

    print(f"[watch] WIRE-SNIFF active on {iface or 'all interfaces'} — detects forged "
          f"ARP even while statically pinned. Watching {sorted(watchset)}. (Ctrl+C to stop)",
          flush=True)

    total = 0
    under_attack = False
    last_summary = 0.0
    last_seen = 0.0
    healthy_since = time.time()
    try:
        while True:
            try:
                frame = s.recv(2048)
            except socket.timeout:
                frame = b""
            now = time.time()
            if len(frame) >= 42:                       # 14 B Ethernet + 28 B ARP
                arp = frame[14:42]
                sender_mac = ":".join("%02x" % b for b in arp[8:14])
                sender_ip = socket.inet_ntoa(arp[14:18])
                good = good_map.get(sender_ip, "")
                if good and sender_ip in watchset and sender_mac != good:
                    total += 1
                    last_seen = now
                    if not under_attack:
                        under_attack = True
                        last_summary = now
                        alert(f"ARP POISONING DETECTED on the wire: {sender_ip} falsely "
                              f"advertised as {sender_mac} (real {good}). If this IP is "
                              f"pinned here the forged reply is ignored (attack blocked).",
                              logf)
                        if do_pin:
                            repin(sender_ip, good)
                    elif now - last_summary >= 3.0:
                        print(f"[watch] {ts()}  ongoing attack: {total} forged ARP replies "
                              f"seen ({sender_ip} claimed as {sender_mac}; real {good}).",
                              flush=True)
                        last_summary = now
            if under_attack and now - last_seen > 6.0:
                under_attack = False
                print(f"[watch] {ts()}  attack appears to have stopped "
                      f"({total} forged replies total). Still watching.", flush=True)
                healthy_since = now
            elif not under_attack and now - healthy_since > 15.0:
                print(f"[watch] {ts()}  OK — no forged ARP on the wire; "
                      f"watching {sorted(watchset)}.", flush=True)
                healthy_since = now
    except KeyboardInterrupt:
        print(f"\n[watch] stopped. {total} forged ARP replies detected in total.", flush=True)
    finally:
        try:
            s.close()
        except OSError:
            pass
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description="ARP-poisoning detector / monitor")
    ap.add_argument("--watch", action="append", default=[], metavar="IP",
                    help="IP to monitor; baseline MAC learned at startup (repeatable)")
    ap.add_argument("--expect", action="append", default=[], metavar="IP=MAC",
                    help="IP with its KNOWN-GOOD MAC (repeatable; most trustworthy)")
    ap.add_argument("--interval", type=float, default=1.0, help="poll seconds (default 1)")
    ap.add_argument("--pin", action="store_true",
                    help="auto-heal: re-apply the correct static entry on poisoning (root/Admin)")
    ap.add_argument("--sniff", action="store_true",
                    help="detect forged ARP on the WIRE (Linux, root) — catches the attack "
                         "even while a static pin silently blocks it (table polling cannot)")
    ap.add_argument("--iface", default="", help="interface for --sniff (default: all)")
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

    # Wire-sniff mode: the only way to SEE the attack while a static pin blocks it
    # (the OS table never changes, so table polling below would report "no
    # poisoning"). Falls through to table polling if it can't run here.
    if args.sniff:
        if sniff_wire(watch_ips, baseline, args.iface, logf, args.pin):
            if logf:
                logf.close()
            return 0

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
