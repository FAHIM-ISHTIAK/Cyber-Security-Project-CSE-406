# TCP Reset Attack — Complete Walkthrough (Code, Events & Outputs)

This document explains **everything that happens** when you run the Phase 1 demo:
the Docker setup, what each source file does, the exact sequence of network
events, and how to read every line of output. It assumes you are **new to
Docker**, so Part 1 is a short primer. If you already know Docker, skip to Part 2.

> Companion to [README.md](README.md) (which is the quick "how to run" guide).
> This file is the "how and why it works" guide.

---

## Part 0 — The 30-second mental model

There are three computers in this demo. Because we don't have three real PCs yet
(that's Phase 2), we fake them with three **Docker containers** on one laptop:

```
   streamserver ─────────────┐        ┌───────────── videoclient
   (172.20.0.10)             │        │              (172.20.0.20)
   sends a video          ┌──┴────────┴──┐           watches the video
   over ONE TCP           │  virtual      │
   connection            │  switch       │
                          │ "attacknet"   │
                          └──────┬────────┘
                                 │
                            attacker (172.20.0.30)
                            lies about who it is (ARP),
                            secretly relays the video,
                            then forges a "hang up" (RST) packet
```

The attack has two halves:

1. **Get in the middle (ARP spoofing):** trick the client and server into
   sending their traffic *through* the attacker.
2. **Kill the connection (RST injection):** once the attacker can read the live
   TCP sequence numbers, it forges a TCP **RST ("reset")** packet that makes each
   side believe the other hung up. The video stops.

---

## Part 1 — Docker primer (for newcomers)

### 1.1 Image vs. Container
- An **image** is a frozen, read-only template — like a `.iso` or a class in
  programming. It contains an OS filesystem + your app + its dependencies.
- A **container** is a *running instance* of an image — like an object created
  from a class. You can start/stop/delete containers freely; the image stays.

In this project each role has its own image, built from a **Dockerfile** (a
recipe). For example [server/Dockerfile](server/Dockerfile) says: "start from
`python:3.11-slim`, install ffmpeg, copy in `stream_server.py`, bake a test
video, and when you run, execute `python3 stream_server.py`."

### 1.2 Why containers instead of virtual machines?
Containers share the host's Linux kernel (on Windows, that kernel is provided by
**WSL2**), so they start in milliseconds and are lightweight. Crucially for us,
each container gets its **own network identity** (its own IP and MAC address), so
three containers behave like three separate machines on a network.

### 1.3 The virtual network ("bridge")
`docker-compose.yml` creates a network called **`attacknet`** of type `bridge`.
A Docker bridge is a **virtual Ethernet switch** living inside your laptop. Every
container we attach to it gets an IP in `172.20.0.0/24`:

| Container      | IP            | MAC (example, changes each build) |
|----------------|---------------|-----------------------------------|
| `streamserver` | 172.20.0.10   | `d2:eb:fe:0d:f4:6d`               |
| `videoclient`  | 172.20.0.20   | `1a:07:06:02:a8:0f`               |
| `attacker`     | 172.20.0.30   | `c2:e2:c1:fe:cd:01`               |

**Key fact that makes this attack necessary:** a switch is a *learning switch*.
It only forwards a unicast frame out the one port where the destination MAC
lives. So the attacker, just sitting there, **cannot** see the server↔client
video — the switch never sends it to the attacker's port. That is exactly why we
need ARP poisoning (Part 3).

### 1.4 The commands you'll actually type

| Command | What it does |
|---|---|
| `docker compose build` | Turn the Dockerfiles into images (slow first time). |
| `docker compose up -d` | Create the network + start all containers in the background (`-d` = detached). |
| `docker compose ps` | List running containers and their status. |
| `docker compose exec <svc> <cmd>` | Run a command **inside** an already-running container. This is how you start the client and the attack. |
| `docker compose logs <svc>` | Show a container's console output. |
| `docker compose down` | Stop and delete the containers + network (images stay). |

Two flags on `exec` you'll see me use:
- `-d` = run the command detached (in the background) so your terminal returns.
- `-T` = don't allocate an interactive terminal (needed when scripting).

### 1.5 Volumes: how files get from container to your laptop
A **volume** maps a host folder into a container. In `docker-compose.yml`:

```yaml
volumes:
  - ./output:/out
```

This means the folder `/out` **inside** the client and attacker containers *is*
the `output/` folder on your laptop. So when the client saves the received video
to `/out/received.mp4`, it instantly appears at
`D:\L-4,T-1\Security Project\output\received.mp4`. Same for the pcap capture.

### 1.6 Capabilities: why only the attacker is "privileged"
Normal containers are restricted for safety. The attacker needs to do
low-level network things (open raw sockets, forge packets, turn on IP
forwarding), so we grant it two Linux **capabilities** in `docker-compose.yml`:

```yaml
cap_add:
  - NET_ADMIN   # change network settings (e.g. enable IP forwarding)
  - NET_RAW     # craft/send raw packets (forged ARP, forged RST)
```

The server and client get **no** special powers — they're ordinary victims.

---

## Part 2 — The files and what each one does

```
docker-compose.yml     the "cast list": 3 containers + the attacknet network
server/
  Dockerfile           recipe for the streamserver image (installs ffmpeg, bakes video)
  stream_server.py     the video server (one long-lived TCP connection)
client/
  Dockerfile           recipe for the videoclient image
  stream_client.py     the victim player (downloads + simulates a playback buffer)
attacker/
  Dockerfile           recipe for the attacker image (installs scapy, tcpdump)
  arp_spoof.py         Step 1: become the man-in-the-middle via ARP poisoning
  rst_attack.py        Step 2: sniff live seq numbers + inject forged RSTs
  attack.sh            convenience: runs arp_spoof + rst_attack together
  capture.sh           saves a Wireshark pcap of the victim connection
defense/
  static_arp.sh        bonus: pin the real MAC so poisoning fails
output/                pcaps + saved video + logs appear here (host-visible)
```

### 2.1 `stream_server.py` — the victim server

What it does, in order:

1. **Reads config** from environment variables (`PORT=9000`, `MEDIA=/media/sample.mp4`,
   `STREAM_SECONDS=90`).
2. **Measures the video** with `ffprobe` to learn its real duration (120 s).
3. **Listens** on TCP `0.0.0.0:9000` and accepts connections (one thread each).
4. For each client, `handle_client()`:
   - Sends a **20-byte header** first:
     `MAGIC("VSTR") + filesize(8 bytes) + duration_ms(8 bytes)`. The client uses
     this to compute the video's bitrate.
   - Then streams the file in `CHUNK`-sized pieces with `sendall()`.
   - **Paces** the send so the whole file takes ~`STREAM_SECONDS` (90 s) to
     deliver. It computes `rate = filesize / 90s` and sleeps between chunks. This
     matters for two reasons: it keeps the connection **long-lived** (so the
     attacker has time to work), and it creates **quiet gaps** the attacker
     exploits later.

The important property: **the entire video is one TCP connection.** That single
connection is what a single RST tears down.

### 2.2 `stream_client.py` — the victim player

1. **Connects** to `172.20.0.10:9000` (the TCP 3-way handshake happens here).
2. **Reads the header**, computes `play_bitrate = filesize / duration`.
3. **Loops** reading data, writing it to `/out/received.mp4`, and tracks
   `received` bytes.
4. **Simulates a playback buffer** so the demo looks like a real video player:
   - `downloaded_seconds = received / play_bitrate` — how much video we have.
   - `played_seconds = time since playback started` — how much we've watched.
   - `buffer = downloaded − played` — the cushion. A healthy stream keeps this
     positive.
   - Playback "starts" after a 3-second prebuffer.
5. **Detects the ending:**
   - If `recv()` returns empty (`b""`) → a graceful close (**FIN**) → "download
     complete".
   - If `recv()` raises **`ConnectionResetError`** → a **RST** arrived → prints
     the big reset banner, then drains the remaining buffer in real time and
     finally prints **PLAYBACK STALLED**.

This is the code that produces the human-readable "the video froze" evidence.

### 2.3 `arp_spoof.py` — becoming the man-in-the-middle

1. **Resolves MACs:** sends normal ARP "who has 172.20.0.10/.20?" and records the
   real MACs of the server and client.
2. **Enables IP forwarding:** writes `1` to `/proc/sys/net/ipv4/ip_forward`. This
   is critical — it tells the attacker's Linux kernel to **relay** packets it
   receives that aren't for itself. Without this, the attacker would be a
   black-hole (a denial of service), and the stream would just freeze — *not* the
   RST attack we're studying.
3. **Poisons, in a loop every 2 s:** sends forged ARP **replies**:
   - To the **client**: "172.20.0.10 (the server) is at *my* MAC."
   - To the **server**: "172.20.0.20 (the client) is at *my* MAC."
   Now both victims send their traffic to the attacker, which relays it onward.
   The video keeps playing — a "clean MITM" — but every packet passes through the
   attacker, who can read it.
4. **Restores on exit:** when you press Ctrl+C, it sends correct ARP replies so
   the caches heal and the network returns to normal.

### 2.4 `rst_attack.py` — sniff live sequence numbers and forge the RST

This is the cleverest file, and it's built to defeat a modern defense. Two
threads run at once:

**(a) A sniffer thread** watches the relayed traffic and continuously learns the
connection's live state (`on_pkt`):
- From the **client's own ACK packets** it reads `tcp.ack`, which *is* the
  client's `RCV.NXT` — the exact sequence number the client expects next. This is
  authoritative (the client itself is telling us).
- It also tracks the **server's data frontier** (`seq + payload length`) and what
  the **server** expects from the client.
- It **ignores RST and SYN packets** — importantly this skips *our own* injected
  RSTs, which would otherwise poison the learned numbers.

**(b) A sender thread** hammers forged RSTs every 30 ms:
- **To the client** (spoofing the server as source): a small **burst** of RSTs
  stepped by ±1 MSS around the learned `RCV.NXT`.
- **To the server** (spoofing the client as source): RSTs at the server's
  expected sequence.

**Why hammer instead of firing once?** Modern Linux implements **RFC 5961**: it
accepts a RST *only if the sequence number exactly equals `RCV.NXT`*. On a live
stream that number keeps moving, so a single guess is usually stale by the time
it arrives (you get a harmless "challenge ACK", not a reset). By hammering
continuously, a shot lands during one of the server's **pacing gaps**, when
`RCV.NXT` is momentarily frozen. And because we reset the **server first**, the
server stops sending, which *freezes* `RCV.NXT` and makes the client-side exact
match trivial. This is precisely the "timing caveat" your proposal describes in
Section 3.

---

## Part 3 — The full event timeline (what happens, step by step)

Below, each step lists **the command**, **what happens on the network**, and
**which code runs**.

### Step 0 — Build & start
```powershell
docker compose build      # Dockerfiles -> images
docker compose up -d      # create attacknet, start all 3 containers
```
- Docker creates the `attacknet` bridge and assigns the static IPs.
- `streamserver` starts running `stream_server.py` → it's now **listening** on
  `:9000`. `videoclient` and `attacker` start but sit idle (`sleep infinity`) so
  *you* control timing.

### Step 1 — Victim starts watching
```powershell
docker compose exec videoclient python3 stream_client.py
```
On the wire (normal TCP):
1. **3-way handshake:** client → `SYN` → server → `SYN-ACK` → client → `ACK`.
   The connection is now `ESTABLISHED`.
2. Server sends the 20-byte header, then paced video **DATA** segments.
3. Client sends **ACK**s back. Its playback buffer grows. You see healthy status
   lines (decoded in Part 4).

At this moment the attacker can see **nothing** of this — the bridge only sends
these unicast frames between server and client ports.

### Step 2 — Attacker gets in the middle
```powershell
docker compose exec attacker ./attack.sh
# (attack.sh runs arp_spoof.py, waits 4s, then runs rst_attack.py)
```
- `arp_spoof.py` resolves MACs, enables IP forwarding, and starts sending forged
  ARP replies.
- **The client's ARP table changes:** `172.20.0.10` now maps to the *attacker's*
  MAC. Same on the server side for `172.20.0.20`.
- Now every server→client (and client→server) frame is delivered to the
  **attacker**, whose kernel **forwards** it to the real destination. The video
  **keeps playing** — but the attacker now sees every byte. This is the
  "man-in-the-middle" position. (You can verify: `docker compose exec videoclient
  ip neigh` shows the server's IP pointing at the attacker's MAC.)

### Step 3 — Attacker forges the RST
- `rst_attack.py`'s sniffer reads the live sequence numbers off the relayed
  traffic (it "locks onto" the connection).
- The sender thread starts hammering forged RSTs at both endpoints.
- **The server accepts its RST almost immediately** (the client's send side is
  stable, so the match is easy). The server closes its socket and **stops
  sending**. Its socket vanishes from the server's table (back to `LISTEN` only).
- With data no longer flowing, the client's `RCV.NXT` **freezes**. The next
  hammered RST to the client hits that exact value → **the client's kernel
  accepts it** and tears the connection down.

### Step 4 — The victim experiences the outage
- Inside `stream_client.py`, the blocked `recv()` raises
  `ConnectionResetError`. The client prints the **RST banner**.
- The video keeps playing from the buffer for a few seconds (the cushion built
  up in Step 1), then the buffer empties and it prints **PLAYBACK STALLED**.
- The client's connection is gone from its own table too.

### Step 5 — Cleanup
- Press **Ctrl+C** in the attacker terminal. `arp_spoof.py` sends corrective ARP
  replies; both caches heal; the network is normal again.

---

## Part 4 — Reading the outputs, line by line

### 4.1 Client: a healthy stream line
```
[client] t= 13.9s  recv 0.28/1.79 MB (15.7%)  net    21 KB/s  buffer  6.6s  play  12.3/120s
```
| Field | Meaning |
|---|---|
| `t= 13.9s` | seconds since this streaming session started |
| `recv 0.28/1.79 MB (15.7%)` | bytes downloaded so far / total file size / percent |
| `net 21 KB/s` | current download throughput (matches the server's pacing) |
| `buffer 6.6s` | seconds of video downloaded but **not yet played** — the cushion. Healthy = growing/steady, positive. |
| `play 12.3/120s` | current playback position / total video length |

While the MITM is active but before the RST, these lines keep advancing
normally — proof that being relayed through the attacker did **not** break the
stream (a clean MITM, not a DoS).

### 4.2 Client: the moment of attack
```
[client] !!! TCP CONNECTION RESET (RST) received — peer sent a
[client] !!! reset with NO preceding FIN. Socket torn down abruptly.
[client] t= 30.4s ... buffer  3.0s ... [buffering-out]
[client] t= 30.9s ... buffer  0.0s ... [BUFFER EMPTY]
[client] ⛔ PLAYBACK STALLED — buffer exhausted, network/connection error.
[client]    Received 0.58/1.79 MB before the reset.
```
- **"RST received … NO preceding FIN"** is the key line: a normal video end would
  be a graceful **FIN** handshake. A forged RST is abrupt and has no FIN — that
  distinction is the whole point of the attack.
- `[buffering-out]` lines show the player surviving on its buffer for a few
  seconds — exactly why a *single* dropped packet wouldn't be noticeable but a
  full reset is.
- **PLAYBACK STALLED** is the user-visible failure. `Received 0.58/1.79 MB`
  tells you it died at 32% of the video.

### 4.3 Attacker: locking on and hammering
```
[rst] locked onto connection: client 172.20.0.20:52068 <-> 172.20.0.10:9000
[rst] hammering: cli_rcv_nxt=1610633299 srv_frontier=1610633299 srv_rcv_nxt=1392406510 | RSTs sent=6
```
| Field | Meaning |
|---|---|
| `locked onto connection` | the sniffer has identified the victim's 4-tuple (IPs + ports) |
| `cli_rcv_nxt` | the **client's** next-expected sequence number (learned from the client's ACKs). This is the value the client-killing RST must match. |
| `srv_frontier` | the newest sequence number the server has sent. When it **equals `cli_rcv_nxt` and stops changing**, the stream has frozen (server already reset) → the client match is now guaranteed. |
| `srv_rcv_nxt` | the sequence the **server** expects from the client (used for the server-killing RST). |
| `RSTs sent=6` | running total of forged RSTs injected. In our run the numbers froze after ~6 packets — the server reset almost instantly, then the client followed. |

A healthy sign of success: `cli_rcv_nxt` and `srv_frontier` **stop advancing**
(the stream froze) and the client's connection disappears from `ss` shortly
after.

### 4.4 Proof #1 — the connection tables (`ss`)
Before the attack:
```
ESTAB  0  0  172.20.0.20:52068  172.20.0.10:9000     # on the client
ESTAB  0  0  172.20.0.10:9000   172.20.0.20:52068    # on the server
```
After the attack:
```
# client: (nothing) — the entry is gone
# server:
LISTEN 0  8  0.0.0.0:9000  0.0.0.0:*                  # only the listener remains
```
The `ESTABLISHED` entries vanishing is hard proof the sockets were destroyed —
this is your proposal's Section 5 criterion "the socket disappears from both
peers' connection tables."

Commands to see this yourself:
```powershell
docker compose exec videoclient ss -tan | Select-String 9000
docker compose exec streamserver ss -tan | Select-String 9000
```

### 4.5 Proof #2 — the packet capture (`output/capture.pcap`)
Open it in **Wireshark** (filter `tcp.port == 9000`). You'll see a long run of
`PSH, ACK` data segments, then suddenly `RST` packets — and **no FIN**. Our
automated count from the verified run:
```
FIN segments: 0
RST segments: 365
```
Sample of the forged RSTs on the wire:
```
172.20.0.10.9000 > 172.20.0.20.52068: Flags [R], seq 1610631839, win 0   # -1 MSS
172.20.0.10.9000 > 172.20.0.20.52068: Flags [R], seq 1610633299, win 0   # exact — THIS one resets the client
172.20.0.10.9000 > 172.20.0.20.52068: Flags [R], seq 1610634759, win 0   # +1 MSS
172.20.0.20.52068 > 172.20.0.10.9000: Flags [R], seq 1392406510, win 0   # RST aimed at the server
```
Notice the source IP on the client-directed RSTs is `172.20.0.10` (the server) —
**that address is spoofed**; the packet actually came from the attacker. The
burst of `seq−1460 / seq / seq+1460` is the ±1 MSS strategy to absorb sequence
drift; the middle one is the exact `RCV.NXT` that the client accepts.

- `FIN segments: 0` proves there was no graceful shutdown.
- `RST segments: 365` is the hammering (many attempts, one lands).

### 4.6 Proof #3 — the saved video (`output/received.mp4`)
This is what the client managed to download before the reset (about 0.58 MB of
the 1.79 MB file in our run). You can double-click it — it plays for a few
seconds and then ends abruptly, a tangible artifact of the interrupted stream.

### 4.7 The `arp.log` sanity check
`output/arp.log` is `arp_spoof.py`'s output. After the cleanup fix it should be
essentially empty (no warnings). While running, you can confirm the MITM took
hold with:
```powershell
docker compose exec videoclient ip neigh
# 172.20.0.10 ... lladdr <ATTACKER_MAC>   <- server IP mapped to attacker = poisoned
```

---

## Part 5 — Why each defense would stop it (bonus)

| Layer | Defense | Effect |
|---|---|---|
| TCP | **RFC 5961** strict sequence check (already in modern Linux) | Blocks *off-path/blind* attackers (they can't guess the exact `RCV.NXT`). Our *on-path* attacker reads the exact value, so it still works — which is exactly why we needed the ARP-poisoning MITM. |
| ARP | **Static ARP entry** ([defense/static_arp.sh](defense/static_arp.sh)) or **Dynamic ARP Inspection** | Pins the real IP→MAC mapping, so forged ARP replies are ignored. The MITM never forms → the attacker can't read the live sequence number → the attack collapses to the (much harder) blind case. |

The takeaway your proposal makes: defending **one** layer isn't enough; the TCP
defense and the ARP defense are **complementary**.

---

## Part 6 — Quick troubleshooting

| Symptom | Cause / fix |
|---|---|
| `docker : term not recognized` in a terminal | That terminal started before Docker was installed. Open a **new** terminal (Docker is already on your machine PATH). |
| Client shows data but attack does nothing | Make sure `arp_spoof.py` is running **first** (the injector needs the MITM to see traffic). `./attack.sh` does this for you. |
| Stream **freezes** but no "RST received" banner | That's a black-hole (IP forwarding off), not the RST attack. `arp_spoof.py` enables forwarding automatically; if you poisoned manually, run `echo 1 > /proc/sys/net/ipv4/ip_forward`. |
| Nothing works after a messy run | `docker compose restart` clears ARP caches and stale sockets; then start over. |
| Want a clean single demo | Bring buffer up first (let the client run ~8 s), then start the attack, and watch the `ss` entry disappear. |

---

*Generated as a study companion for the CSE 406 TCP Reset Attack project,
Phase 1 (Docker). All numbers above are from a real, verified run on this
machine.*
