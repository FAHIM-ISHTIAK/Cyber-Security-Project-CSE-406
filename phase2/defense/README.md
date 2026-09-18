# Phase 2 — Defense (Three-Machine Physical Demonstration)

CSE 406 — Cyber Security Sessional · Project 2026 · Group 03, Section A1
(2105004 Fahim Ishtiak, 2105001 Nahid Hossain Redom)

This is the **defense** for the Phase 2 attack (three separate physical machines —
**server**, **client**, **attacker** — on one Wi-Fi/LAN segment). It implements
both defenses from the design proposal **Section 6** and, unlike the Phase-1
`defense/static_arp.sh` (Docker-only, hard-coded `eth0` + `172.20.0.x`), it is
**cross-platform** (Linux / macOS / Windows) and auto-detects the real LAN
interface — because in Phase 2 the client and server can be any OS.

> ⚠️ **Ethics & scope.** Same as the attack: only on an isolated test network you
> control. These defense tools are safe (they only harden the local host).

---

## 0. Why these two defenses (and why you need both)

The attack has two layers, so the defense does too:

| Layer | Attack step | Defense | What it does | Stops our attacker? |
|-------|-------------|---------|--------------|---------------------|
| TCP | forge an in-window RST | **RFC 5961** exact-match RST rule (§6.1) | RST accepted only if `seq == RCV.NXT` exactly; otherwise a challenge ACK | **No** by itself — the on-path attacker reads the exact `RCV.NXT` off the wire. Defeats a *blind/off-path* attacker. |
| ARP | poison caches to become MITM | **Static ARP + monitoring / DAI** (§6.2) | pin the peer's real IP→MAC so forged ARP is ignored; detect poisoning | **Yes** — no MITM ⇒ the attacker never reads `RCV.NXT` ⇒ the attack collapses to the (defeated) blind case above. |

**The takeaway the proposal makes:** the two are *complementary*. RFC 5961 is the
always-on TCP baseline; the ARP-layer defense is what actually removes the on-path
position this specific attack depends on. In our three-machine setup the
**ARP-layer defense is the one that stops the demo.**

---

## 1. What's in this folder

| File | Runs on | Purpose |
|------|---------|---------|
| `static_arp.sh` | Linux / macOS victim | pin / unpin / show / verify a static IP→MAC entry (§6.2 prevent) |
| `static_arp.ps1` | Windows victim (Admin) | same, via `netsh` / `New-NetNeighbor` |
| `arp_watch.py` | any victim (stdlib, no deps) | **detect** ARP poisoning live (MAC change or one-MAC-many-IPs); optional auto-heal |
| `defend.sh` | Linux / macOS victim | one-shot: pin the peer (+gateway) **and** start the monitor |
| `defend.ps1` | Windows victim (Admin) | same, for Windows |
| `rfc5961_check.sh` | Linux victim | verify / explain the RFC 5961 TCP-layer defense (§6.1) |

The "peer" is **the other endpoint of the video flow**: on the **client** the peer
is the **server**; on the **server** the peer is the **client**. Pinning the
**gateway** too is good practice.

### Run it on BOTH victims (why one side isn't enough)

The **server and client are the two victims**; the attacker is never "defended".
To *read* the live sequence numbers the attacker must see the traffic, which needs
**both** caches poisoned (client→server *and* server→client redirected through it):

- Pin **only the client** → client→server goes direct, but the **server is still
  poisoned**, so the attacker still sees the server→client half and can still
  approximate the client's `RCV.NXT` and forge RSTs → **partial** protection.
- Pin **both** → neither direction transits the attacker → it sees **nothing**,
  can't read `RCV.NXT`, and the attack collapses to the blind case RFC 5961 already
  defeats → **full** protection.

So for a clean "attack fully fails" result, run the defense on **both** machines.

### Turning the defense ON and OFF (for an attack-then-defense demo)

The defense is fully toggleable, so you can show the attack succeed, then switch
the defense on and show it fail:

| | Linux/macOS (each victim, as root) | Windows (each victim, Admin) |
|---|---|---|
| **ON**  | `sudo ./defend.sh --peer <PEER_IP> --peer-mac <PEER_MAC> --gateway auto --watch` | `.\defend.ps1 -Peer <PEER_IP> -PeerMac <PEER_MAC> -Gateway auto -Watch` |
| **OFF** | `sudo ./defend.sh --peer <PEER_IP> --gateway auto --off` | `.\defend.ps1 -Peer <PEER_IP> -Gateway auto -Off` |

`--off` / `-Off` removes the static entries (ARP goes dynamic again); stop the
`arp_watch` monitor with **Ctrl+C**. **Always pass `--peer-mac` when toggling ON**
so you pin the *real* MAC even if the attacker is active — auto-learn is only safe
before the attacker starts (see §2).

---

## 2. The one thing to get right: learn the *real* MAC first

A static entry only helps if it pins the **real** MAC. Two ways, best first:

1. **Read it on the peer itself and pass it explicitly** (trustworthy — never sees
   the attacker):
   - Linux peer:   `cat /sys/class/net/<iface>/address`
   - Windows peer: `getmac /v`   ·   macOS peer: `ifconfig <iface> | grep ether`
2. **Auto-learn** (the scripts ping the peer and read the resulting cache) —
   only reliable if you do it **BEFORE** the attacker starts poisoning, otherwise
   you'd pin the attacker's MAC. `defend.*` and `static_arp.* pin` auto-learn when
   you don't pass a MAC.

---

## 3. Quickest path — one command per victim (recommended)

Do this on the two victim machines **before** starting the attacker.

### Client machine (pin the SERVER)
- **Linux/macOS:**
  ```bash
  sudo ./defend.sh --peer <SERVER_IP> --peer-mac <SERVER_MAC> --gateway auto --watch
  ```
- **Windows (Admin PowerShell):**
  ```powershell
  .\defend.ps1 -Peer <SERVER_IP> -PeerMac <SERVER_MAC> -Gateway auto -Watch
  ```

### Server machine (pin the CLIENT)
- **Linux/macOS:**
  ```bash
  sudo ./defend.sh --peer <CLIENT_IP> --peer-mac <CLIENT_MAC> --gateway auto --watch
  ```
- **Windows (Admin PowerShell):**
  ```powershell
  .\defend.ps1 -Peer <CLIENT_IP> -PeerMac <CLIENT_MAC> -Gateway auto -Watch
  ```

Omit `--peer-mac` / `-PeerMac` to auto-learn (only before the attack). `--watch`
keeps the monitor in the foreground so you can *see* the attacker try and fail.
Use `--pin-watch` / `-PinWatch` to also **auto-heal** any un-pinned host that gets
poisoned. Detection-only (no pinning): add `--no-pin` / `-NoPin`.

---

## 4. Or run the pieces by hand

**Pin (prevent):**
```bash
# Linux/macOS client, pin the server:
sudo ./static_arp.sh pin <SERVER_IP> <SERVER_MAC>     # MAC optional (auto-learn)
sudo ./static_arp.sh verify <SERVER_IP> <SERVER_MAC>  # confirm it took
sudo ./static_arp.sh show
```
```powershell
# Windows client, pin the server (Admin):
.\static_arp.ps1 pin <SERVER_IP> <SERVER_MAC>
.\static_arp.ps1 verify <SERVER_IP> <SERVER_MAC>
```

**Monitor (detect), on any victim, no root needed for detect-only:**
```bash
python3 arp_watch.py --expect <SERVER_IP>=<SERVER_MAC> --expect <GW_IP>=<GW_MAC>
# or auto-baseline the current MACs (start before the attacker):
python3 arp_watch.py --watch <SERVER_IP> --watch <GW_IP>
# detect AND re-pin on poisoning (root/Admin):
sudo python3 arp_watch.py --watch <SERVER_IP> --pin
```

**Undo the static entries afterwards:**
```bash
sudo ./static_arp.sh unpin <SERVER_IP>          # Linux/macOS
```
```powershell
.\static_arp.ps1 unpin <SERVER_IP>              # Windows (Admin)
```

---

## 5. Full demo runbook — show the attack, THEN the defense (spec §5 / Table 2)

Run the identical attack twice — once undefended, once defended — and compare.
This is the graded "success with vs. without defense" evidence.

**Step 0 — record the real MACs first (once, before any attack).** On each victim,
read the *other* endpoint's MAC and note it — you'll pass these as `--peer-mac` so
toggling is always correct:
- Linux server/client: `cat /sys/class/net/<iface>/address`
- Windows: `getmac /v`   ·   macOS: `ifconfig <iface> | grep ether`
Call them **SERVER_MAC** and **CLIENT_MAC**.

**Step 1 — attack with defense OFF.** Make sure nothing is pinned (fresh boot, or
run the OFF command below). Start server → client → attacker (`phase2/README.md §4`).
→ The client shows the RST banner and **PLAYBACK STALLED**. ✅ attack succeeds.

**Step 2 — stop the attacker** (Ctrl+C; it restores ARP). Restart the stream
(server still running; re-run the client).

**Step 3 — turn the defense ON (both victims).**
- Client machine (pin the server):
  `sudo ./defend.sh --peer <SERVER_IP> --peer-mac <SERVER_MAC> --gateway auto --watch`
- Server machine (pin the client):
  `sudo ./defend.sh --peer <CLIENT_IP> --peer-mac <CLIENT_MAC> --gateway auto --watch`
  (Windows: the `defend.ps1 -Peer … -PeerMac … -Gateway auto -Watch` form.)

**Step 4 — re-run the attacker.** Now:
   - The **client keeps playing** — status lines keep advancing, no RST banner.
   - The **attacker's `run_attack.sh` never locks on** — its injector stays at
     "waiting to lock onto the victim connection …" and never sees DATA, because
     poisoning no longer redirects the flow.
   - The **monitor** on each victim prints an `ARP POISONING …` alert each time the
     attacker sends a forged reply — visible proof the attempt happened *and* was
     neutralised (the pinned entry didn't move).
   ✅ attack fails.

**Step 5 — turn the defense OFF again** (to repeat, or hand back a clean machine):
- `sudo ./defend.sh --peer <PEER_IP> --gateway auto --off` on each victim, and
  **Ctrl+C** the monitor. Re-running the attack now succeeds again — a clean toggle.

Confirm the cache held during Step 4 (the server IP still maps to its **real** MAC,
not the attacker's):
- Linux:   `./static_arp.sh verify <SERVER_IP> <SERVER_MAC>`  → `OK`
- Windows: `.\static_arp.ps1 verify <SERVER_IP> <SERVER_MAC>` → `OK`
- either:  compare against `arp -a` / `ip neigh` while the attacker runs.

Record for the report: success rate with vs. without defense, and (from
`rfc5961_check.sh` + the "no-MITM" run) that RFC 5961 alone stops the *blind* case
but not the on-path one — which is exactly why the ARP-layer defense is needed.

---

## 6. Managed-switch note (Dynamic ARP Inspection)

The proposal (§6.2) also lists **Dynamic ARP Inspection (DAI)** as the scalable
version of this defense: on a managed switch with DHCP snooping, DAI validates
every ARP reply against the trusted binding table and drops forged ones — so no
victim configuration is needed at all. On the consumer Wi-Fi router used for this
demo DAI usually isn't available, so we implement its host-side equivalents
(static entries + monitoring) here. Static ARP is "impractical at scale" (§6.2)
but exact for a small fixed test bed; `arp_watch.py` covers the detection role
that DAI would otherwise provide.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `pin` learned the wrong MAC | You ran it *after* the attacker started. Unpin, stop the attacker, re-learn, or pass `--peer-mac` read on the peer. |
| Windows: "access denied" / no effect | Not elevated. Use an **Admin** PowerShell. |
| Linux: `Operation not permitted` | Not root. Use `sudo`. |
| Attack still succeeds with defense on | You pinned only one victim, or the attacker was already MITM before pinning. Pin **both** victims and re-establish the stream. Verify with `verify`. |
| Monitor never alerts during attack | It's watching the wrong IPs, or the pinned entry is holding so cleanly the OS table never changed — check the attacker actually ran; add the gateway to `--watch`. |
| Static entry vanished after reconnecting Wi-Fi | Re-run `pin` (permanent entries are per-link and reset when the interface drops). |

---

## 8. How this maps to the proposal

| Proposal | Phase 2 defense artifact |
|----------|--------------------------|
| §6.1 RFC 5961 strict sequence validation | `rfc5961_check.sh` + the "no-MITM" contrast run |
| §6.2 static ARP entries | `static_arp.sh` / `static_arp.ps1`, `defend.sh` / `defend.ps1` |
| §6.2 ARP-layer detection (host-side DAI equivalent) | `arp_watch.py` |
| §6.2 Dynamic ARP Inspection (managed switch) | §6 note (switch feature; host equivalents provided) |
| §5 / Table 2 success with vs. without defense | §5 above (run attack twice, compare) |
