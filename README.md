# TCP Reset Attack on Video Streaming — Phase 1 (Single-PC Docker Simulation)

CSE 406 — Cyber Security Sessional · Project 2026 · Group 03, Section A1
(2105004 Fahim Ishtiak, 2105001 Nahid Hossain Redom)

This is **Phase 1** of the design proposal: all three roles run as Docker
containers on one machine, joined by a user-defined bridge network that
reproduces the on-path / LAN-local threat model. The attacker becomes a
man-in-the-middle via **ARP cache poisoning**, reads the live TCP sequence
numbers off the relayed video stream, and injects a **forged RST** that tears
down the victim's connection — stalling playback.

> ⚠️ **Ethics & scope.** Everything runs inside an isolated Docker bridge
> network (`172.20.0.0/24`). No third-party, campus, or production traffic is
> ever touched. Use only against this test bed.

---

## 1. Topology

```
Single host (Docker Engine) — bridge network "attacknet" 172.20.0.0/24
  ┌────────────────────┐   ┌────────────────────┐   ┌────────────────────┐
  │ streamserver        │   │ attacker            │   │ videoclient         │
  │ 172.20.0.10 :9000   │   │ 172.20.0.30         │   │ 172.20.0.20         │
  │ serves .mp4 / 1 TCP │   │ NET_ADMIN+NET_RAW   │   │ victim player       │
  └────────────────────┘   │ ARP-poison→sniff→RST │   └────────────────────┘
                           └────────────────────┘
```

| Container      | IP            | Role                                             |
|----------------|---------------|--------------------------------------------------|
| `streamserver` | 172.20.0.10   | Raw-TCP video streamer (single long-lived socket)|
| `videoclient`  | 172.20.0.20   | Victim; downloads + simulates buffered playback  |
| `attacker`     | 172.20.0.30   | ARP poisoning, sniffing, forged RST injection    |

---

## 2. Prerequisites

- **Docker Desktop** (or Docker Engine) with the Compose plugin.
  On Windows use Docker Desktop with the **WSL2 backend** (Linux containers) —
  the attacker needs Linux capabilities `NET_ADMIN`/`NET_RAW`.
  Check: `docker --version` and `docker compose version`.

> This repository was authored on a machine without Docker installed, so the
> images have not been built here — install Docker, then run the commands below.

---

## 3. Build & start

From this folder:

```bash
docker compose build          # builds server (with a baked 120s test video), client, attacker
docker compose up -d          # starts all three containers
docker compose ps             # confirm streamserver / videoclient / attacker are Up
```

The **server auto-starts** and listens on `172.20.0.10:9000`. The client and
attacker stay idle (`sleep infinity`) so *you* control timing.

---

## 4. Run the attack (open 3 terminals)

Open three terminals, one exec session each.

### Terminal A — victim starts watching

```bash
docker compose exec videoclient python3 stream_client.py
```

You'll see a healthy stream: buffer grows, playback advances, e.g.

```
[client] t= 12.0s  recv 1.60/7.5 MB (21%)  net  512 KB/s  buffer  4.2s  play  9.0/120s
```

### Terminal B *(optional)* — capture for Wireshark

```bash
docker compose exec attacker ./capture.sh /out/capture.pcap
```

Writes `output/capture.pcap` on the host (the `output/` folder is mounted).

### Terminal C — the attacker

Easiest (ARP-poison + sniff-and-inject, sustained hammer until Ctrl+C):

```bash
docker compose exec attacker ./attack.sh
```

Or run the two stages by hand to see each step:

```bash
# 1) become MITM (leave running; Ctrl+C later restores ARP)
docker compose exec attacker python3 arp_spoof.py --client 172.20.0.20 --server 172.20.0.10

# 2) in another attacker shell, inject (Ctrl+C to stop)
docker compose exec attacker python3 rst_attack.py \
    --client 172.20.0.20 --server 172.20.0.10 --port 9000
```

How the injector beats RFC 5961's exact-match rule: it learns the client's live
`RCV.NXT` from the **client's own ACKs** and hammers forged RSTs continuously, so
one lands during the streamer's pacing gap when `RCV.NXT` is momentarily stable.
Resetting the server first (default) freezes the stream, which makes the
client-side exact match trivial. Useful flags for `rst_attack.py` / `attack.sh`:
- `--no-server` — reset only the client (default resets **both** endpoints).
- `--burst N` — RSTs per candidate, stepped by one MSS around `RCV.NXT`, to
  absorb residual drift on a fast stream (spec §3 timing caveat). Default 3.
- `--interval S` — seconds between hammer rounds (default 0.03).
- `--duration S` — stop after S seconds (`0` = run until Ctrl+C, the default).

---

## 5. What success looks like

**Terminal C (attacker):**
```
[rst] #1 injected RST -> CLIENT seq=1234567 (paylen=1448)  + SERVER seq=890
```

**Terminal A (victim):** the socket dies with no FIN, the buffer drains, playback stalls:
```
[client] !!! TCP CONNECTION RESET (RST) received — peer sent a
[client] !!! reset with NO preceding FIN. Socket torn down abruptly.
[client] t= 30.4s ... buffer  3.0s ... [buffering-out]
[client] ⛔ PLAYBACK STALLED — buffer exhausted, network/connection error.
```

**Verify the teardown** — the connection entry disappears from the client:
```bash
docker compose exec videoclient ss -tan | grep 9000    # gone after the reset
```

**On the wire** — open `output/capture.pcap` in Wireshark: you'll see a run of
DATA segments then an `RST` **with no preceding FIN/FIN-ACK** — visually distinct
from a graceful close. Filter: `tcp.port == 9000`.

---

## 6. Measuring (spec Section 5 / Table 2)

- **Success rate / attempts per success:** the injector prints a running
  `RSTs sent=` counter; note how many were sent before the client's connection
  disappears from `ss` (RFC 5961 exact-match drift on a fast stream). Compare
  `--no-server` (client only) against the default (server reset first, which
  freezes the stream and makes the client match land almost immediately).
- **Client auto-retry:** restart the client with retry on to see it reconnect,
  and watch that sustained injection is needed to keep it down:
  ```bash
  docker compose exec -e RECONNECT=1 videoclient python3 stream_client.py
  ```
- **Time-to-disruption:** the client status line timestamps when the RST lands
  and when playback stalls.

---

## 7. Defense demo (bonus, spec Section 6.2)

Pin the server's real MAC on the client so forged ARP replies are ignored — the
MITM never forms and the attack collapses to the blind case:

```bash
# get the server's real MAC
docker compose exec streamserver cat /sys/class/net/eth0/address
# pin it on the client (client has no NET_ADMIN by default; add it or run as needed)
docker compose exec videoclient /bin/sh -c "ip neigh replace 172.20.0.10 lladdr <MAC> nud permanent dev eth0"
```
See `defense/static_arp.sh` for a helper and notes. Re-run the attack: the
injector never sees the flow and playback continues.

---

## 8. Reset / tear down

```bash
docker compose down           # stop & remove containers + network
docker compose down --rmi local   # also remove the built images
```

If ARP got left poisoned (you killed the spoofer un-gracefully), just restart
the affected container; caches are per-container and reset on restart.

---

## 9. File layout

```
docker-compose.yml        three services on the attacknet bridge
server/  Dockerfile, stream_server.py     raw-TCP streamer (+ baked test video)
client/  Dockerfile, stream_client.py     victim player w/ buffered-playback sim
attacker/Dockerfile, arp_spoof.py, rst_attack.py, attack.sh, capture.sh
defense/ static_arp.sh                    ARP-layer defense demo
output/                                   saved stream + pcaps (host-mounted)
```

---

## 10. How the code maps to the proposal

| Proposal                                   | Implementation                              |
|--------------------------------------------|---------------------------------------------|
| §1.2 custom raw-TCP streamer, one socket   | `server/stream_server.py`                   |
| §2.1 three containers on a bridge          | `docker-compose.yml` (`attacknet`)          |
| §2.3 ARP poisoning + IP forwarding (MITM)  | `attacker/arp_spoof.py`                      |
| §2.4 / §3 read live seq, forge RST         | `attacker/rst_attack.py`                     |
| §3 timing caveat (burst around RCV.NXT)    | `rst_attack.py --burst`                      |
| §5 outcomes (stall, no-FIN RST, ss/pcap)   | client status + `capture.sh` + `ss`         |
| §6.2 ARP-layer defense                      | `defense/static_arp.sh`                      |

Implementation Phases **A–E** of the proposal are all covered here inside
Docker; Phase 2 (three physical machines) reuses the same `attacker/` scripts
unchanged — only the IPs and `-i <iface>` change.
```
