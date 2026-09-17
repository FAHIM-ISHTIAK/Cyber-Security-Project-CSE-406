# Phase 2 — Three-Machine Physical Demonstration

CSE 406 — Cyber Security Sessional · Project 2026 · Group 03, Section A1
(2105004 Fahim Ishtiak, 2105001 Nahid Hossain Redom)

This is **Phase 2** of the design proposal (§2.2): the same logical attack as
Phase 1, but with the three roles running on **three separate physical machines**
on a shared **Wi-Fi** LAN, to prove the attack is not an artifact of the Docker
virtual network stack.

The attack code is **identical** to Phase 1 — `attacker/arp_spoof.py`,
`attacker/rst_attack.py`, `server/stream_server.py`, `client/stream_client.py`
are reused unchanged. Phase 2 only adds native (no-Docker) launcher scripts and
this setup guide. Only the IPs and the network interface change.

> ⚠️ **Ethics & scope.** Run this **only** on an isolated test network you
> control (a dedicated router / travel AP / phone hotspot set up for this
> project). Never ARP-poison or inject RSTs on campus Wi-Fi, a shared network,
> or any host that is not one of your three test machines.

---

## 0. Roles and the one hard requirement

| Machine | Role | OS |
|---------|------|----|
| PC 1 — **Server** | serves the video over one long-lived TCP socket | Windows **or** Linux/macOS |
| PC 2 — **Client** (victim) | watches the stream, buffers, then stalls on RST | Windows **or** Linux/macOS |
| PC 3 — **Attacker** | ARP-poisons, sniffs, injects the forged RST | **Linux (required)** |

**The attacker must be Linux.** ARP spoofing and raw RST injection need raw
sockets, scapy, and `/proc/sys/net/ipv4/ip_forward`, which do not exist natively
on Windows/macOS. Since your attacker host is Windows/macOS, run the attacker
inside a **Linux VM** (Kali or Ubuntu) — see §2, which is the most important
section for your setup.

Copy this **whole repository folder** to each of the three machines (the
launchers reference `../server`, `../client`, `../attacker` by relative path).

---

## 1. Network: get all three on the SAME Layer-2 segment

The attack is on-path and LAN-local: server, client, and attacker must share one
broadcast domain so ARP replies from the attacker reach the victims. On a home
router this means all three are behind the **same router** (its Wi-Fi and its
LAN Ethernet ports are one bridged L2 segment) and in the **same subnet**
(e.g. all `192.168.1.x`).

Two Wi-Fi-specific things **will silently break the demo** if ignored:

1. **AP / client isolation must be OFF.** Many APs — especially guest networks
   and phone hotspots — block station-to-station traffic. With it on, the
   attacker cannot even ping the victims and ARP poisoning never lands. Use a
   router/travel AP whose admin page lets you turn "AP isolation" / "client
   isolation" / "station isolation" **off**. (Some phone hotspots force it on
   and cannot disable it — don't use those.)
2. **A VM cannot ARP-spoof when bridged over the host's Wi-Fi** (see §2).

Find each machine's IP:
- **Windows:** `ipconfig` → "IPv4 Address" of the Wi-Fi adapter, or run
  `phase2\server\run_server.ps1` which prints it.
- **Linux/macOS:** `ip -4 addr` (Linux) or `ifconfig` (macOS), or the
  `run_server.sh` launcher prints it.

Write down: **SERVER_IP**, **CLIENT_IP** (and later the attacker's own VM IP).

---

## 2. Attacker networking (the critical part for a Wi-Fi + VM setup)

Your attacker host is Windows/macOS, so the attacker runs in a Linux VM. For
ARP poisoning to work, the **VM must appear on the Wi-Fi LAN as its own station
with its own MAC** — the same L2 segment as the server and client. NAT (the VM
default) will **not** work: a NAT'd VM is hidden behind the host and cannot send
ARP replies onto the LAN.

Pick **one** of these, in order of reliability:

### Option A (most reliable) — attacker on Ethernet, victims on Wi-Fi
Plug the **attacker host into a LAN Ethernet port of the same router** (or use a
USB-Ethernet adapter). In the VM, set the network adapter to **Bridged** to that
wired NIC. Ethernet bridging works perfectly; the router bridges its wired ports
and Wi-Fi into one L2 segment, so the wired attacker is on-path for the two
wireless victims. **Recommended if you have any wired port free.**

### Option B — USB Wi-Fi dongle passed through to the VM
Attach a USB Wi-Fi adapter and use your hypervisor's **USB passthrough** to give
it directly to the Linux VM. The VM's Linux driver associates the dongle with
the AP as an independent station with the VM's own MAC — a genuine L2 peer, so
ARP spoofing works. Needs a dongle with Linux driver support.

### Option C (least reliable) — Bridged over the host's built-in Wi-Fi
VMware/VirtualBox can bridge to Wi-Fi, but they MAC-translate to the host's
Wi-Fi MAC because 802.11 associates one MAC per station. Forged/gratuitous ARP
from the VM is frequently dropped, so ARP poisoning **often fails**. Try it only
if A and B are impossible, and verify with `preflight.sh` before trusting it.

> **Do not use** VirtualBox/VMware **NAT**, or **WSL2** (NAT/mirrored) — none put
> the attacker on the LAN as an ARP-capable L2 peer.

Whichever option you choose, confirm the VM got a **real LAN IP in the same
subnet** as the victims (e.g. `192.168.1.x`, *not* `10.0.2.x` NAT or a
`169.254.x` link-local). `preflight.sh` checks this for you.

---

## 3. Install & sanity-check (attacker VM)

Inside the Linux VM, from the repo's `phase2/attacker/` folder:

```bash
./setup.sh                                        # creates venv, installs scapy + system libs (uses sudo only for apt)
sudo ./preflight.sh --server <SERVER_IP> --client <CLIENT_IP>
```

`preflight.sh` verifies the tooling, auto-detects the LAN interface, confirms the
VM has a real LAN IP, and — crucially — **pings the server and client and learns
their MACs**. If a victim is UNREACHABLE, that is almost always AP client
isolation (§1) or the VM being on NAT (§2). Fix those before continuing; the
attack cannot work until preflight passes.

---

## 4. Run the demo (three machines, in order)

### PC 1 — Server (start first)
- **Windows:** `powershell -ExecutionPolicy Bypass -File phase2\server\run_server.ps1`
- **Linux/macOS:** `phase2/server/run_server.sh`

It prints its LAN IP (that's **SERVER_IP**) and serves a 120s test video
(auto-generated with ffmpeg; without ffmpeg it makes an ~8 MB synthetic
placeholder that works for the attack but is not playable; or set
`MEDIA=/path/to/video.mp4`). If the client cannot connect, allow inbound TCP 9000
through the server's firewall (the launcher prints the exact command).

### PC 2 — Client / victim (start second)
- **Windows:** `powershell -ExecutionPolicy Bypass -File phase2\client\run_client.ps1 <SERVER_IP>`
- **Linux/macOS:** `phase2/client/run_client.sh <SERVER_IP>`

You should see a healthy stream: buffer grows, playback advances, e.g.
```
[client] t= 12.0s  recv 1.60/7.5 MB (21%)  net  512 KB/s  buffer  4.2s  play  9.0/120s
```

### PC 3 — Attacker (start third, in the Linux VM)
Optionally capture first, in a second VM shell:
```bash
sudo ./capture.sh --server <SERVER_IP> --client <CLIENT_IP> -o ../output/phase2_capture.pcap
```
Then launch ARP poisoning + RST injection:
```bash
sudo ./run_attack.sh --server <SERVER_IP> --client <CLIENT_IP>
# reset only the client (leave server up):     ... -- --no-server
# absorb seq drift on a fast stream (spec §3):  ... -- --burst 5
```
`run_attack.sh` auto-detects the interface, poisons both victims (IP forwarding
on, so the stream keeps flowing = a clean MITM), waits 4s, then hammers forged
RSTs. **Ctrl+C** stops it and restores the victims' ARP caches.

---

## 5. What success looks like (spec §5)

- **Client (PC 2):** the socket dies with **no FIN**, the buffer drains, playback
  stalls with a network/connection error:
  ```
  [client] !!! TCP CONNECTION RESET (RST) received — peer sent a
  [client] !!! reset with NO preceding FIN. Socket torn down abruptly.
  [client] ⛔ PLAYBACK STALLED — buffer exhausted, network/connection error.
  ```
- **Connection table** disappears on the client:
  - Windows: `netstat -ano | findstr :9000`  (gone after the reset)
  - Linux/macOS: `ss -tan | grep 9000` / `netstat -an | grep 9000`
- **On the wire:** open `phase2/output/phase2_capture.pcap` in Wireshark
  (filter `tcp.port == 9000`): a run of DATA segments, then an **RST with no
  preceding FIN/FIN-ACK** — visually distinct from a graceful close.

---

## 6. Measuring (spec §5 / Table 2)

Repeat and record, then compare against your Phase 1 (Docker) numbers:

| Metric | How to measure here |
|--------|---------------------|
| Success rate (%) | successful resets over N runs |
| Time-to-disruption | client status timestamps: RST received → stall |
| RST attempts per success | the injector's running `RSTs sent=` counter at teardown |
| Behavior vs. client retry | re-run client with `RECONNECT=1` (`.sh`) / `$env:RECONNECT="1"` (`.ps1`); note that sustained injection is needed to keep it down |
| Success with vs. without defense | §7 |

A useful comparison point: the default (reset the **server** too) freezes the
stream and makes the client-side exact-match RST land almost immediately;
`--no-server` (client only) is harder and shows the RFC 5961 seq-drift effect.

---

## 7. Defense demo (spec §6.2)

**Static ARP entry** — pin the server's real MAC on the client so forged ARP
replies are ignored; the MITM never forms and the attack collapses to the blind
case. Get the server's real MAC (from the server, **before** attacking):
- Windows: `getmac /v` ; Linux: `cat /sys/class/net/<iface>/address`.

Pin it on the client:
- **Windows (Admin):** `netsh interface ipv4 add neighbors "Wi-Fi" <SERVER_IP> <SERVER-MAC>`
  (remove with `netsh interface ipv4 delete neighbors "Wi-Fi" <SERVER_IP>`)
- **Linux:** `sudo ip neigh replace <SERVER_IP> lladdr <SERVER-MAC> nud permanent dev <iface>`
  (see `defense/static_arp.sh`).

Re-run the attack: the injector never sees the flow and playback continues.
(RFC 5961 exact-match is already demonstrated by the on-path attack succeeding
where a blind in-window guess would only draw a challenge ACK — contrast the
on-path run here with the "no MITM" run above.)

---

## 8. Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `preflight.sh`: victim UNREACHABLE | AP client isolation ON (§1), or wrong IP, or VM on NAT (§2). |
| VM IP is `10.0.2.x` or `169.254.x` | VM is on NAT / bridge failed. Use §2 Option A or B. |
| ARP poisoning "works" but attacker never sees DATA | Wi-Fi bridge MAC-translation (§2 Option C failing). Switch to A/B. |
| Client can't connect to server at all | Server firewall blocking TCP 9000 (server launcher prints the allow rule); or different subnets. |
| RST sent but client not resetting | Fast stream seq drift (spec §3): add `-- --burst 5`; keep the default server-reset; ensure exact 4-tuple/port. |
| Client instantly reconnects | Expected with `RECONNECT=1`; sustained hammering keeps it down (spec §5). |
| ARP left poisoned after a crash | Just reconnect the victim to Wi-Fi, or `ip neigh flush all` / reboot; caches self-heal. |

---

## 9. How Phase 2 maps to the proposal

| Proposal | Phase 2 artifact |
|----------|------------------|
| §2.2 three physical machines, shared LAN | this guide + native launchers |
| §2.3 ARP poisoning + IP forwarding (MITM) | `attacker/arp_spoof.py` (reused), `run_attack.sh` |
| §2.4 / §3 read live seq, forge RST, seq-drift burst | `attacker/rst_attack.py` (reused) |
| §2.3 SPAN/port-mirror fallback | N/A on Wi-Fi; `capture.sh` records the on-path view instead |
| §5 outcomes (stall, no-FIN RST, ss/netstat/pcap) | client output + `capture.sh` + `netstat`/`ss` |
| §6.2 ARP-layer defense (static ARP) | §7 above + `defense/static_arp.sh` |

Everything runs on real hardware over Wi-Fi, confirming the Phase 1 result holds
outside the Docker virtual network stack.
