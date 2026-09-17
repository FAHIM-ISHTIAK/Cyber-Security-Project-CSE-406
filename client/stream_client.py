#!/usr/bin/env python3
"""
stream_client.py — Custom raw-TCP video client (the victim/player).

Connects to the stream server over a single long-lived TCP connection, reads
the video, and saves it to disk. It also simulates a playback buffer so the
demo shows the exact behaviour the design proposal predicts:

  * normal case  -> buffer stays healthy, download completes cleanly (FIN).
  * RST attack   -> the socket dies abruptly with NO FIN; playback continues
                    from the buffer, then STALLS once the buffer drains and
                    the "player" reports a network/connection error.

Environment:
  SERVER_IP, SERVER_PORT   where to connect (default 172.20.0.10:9000)
  OUTFILE                  where to save the stream (default /out/received.mp4)
  PREBUFFER_SECONDS        buffer to build before playback starts (default 3)
  RECONNECT                "1" to auto-retry after a reset (default "0")
  RECONNECT_DELAY          seconds between retries (default 3)
"""
import os
import socket
import struct
import sys
import time

# Phase 2 runs this client natively on mixed OSes. On a Windows console the
# default code page (cp1252) cannot encode the status emoji and print() would
# crash at the success/stall message. Force UTF-8 with a safe fallback so the
# same code runs identically in a Linux container and on a native Windows host.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

SERVER_IP = os.environ.get("SERVER_IP", "172.20.0.10")
SERVER_PORT = int(os.environ.get("SERVER_PORT", "9000"))
OUTFILE = os.environ.get("OUTFILE", "/out/received.mp4")
PREBUFFER = float(os.environ.get("PREBUFFER_SECONDS", "3"))
RECONNECT = os.environ.get("RECONNECT", "0") == "1"
RECONNECT_DELAY = float(os.environ.get("RECONNECT_DELAY", "3"))

MAGIC = b"VSTR"
HEADER_LEN = 4 + 8 + 8


def recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("connection closed while reading header")
        buf += chunk
    return buf


def human_mb(b: int) -> str:
    return f"{b / 1_048_576:.2f}"


def play_session() -> str:
    """Run one streaming session. Returns 'complete', 'reset', or 'error'."""
    print(f"[client] connecting to {SERVER_IP}:{SERVER_PORT} ...", flush=True)
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(10)
    try:
        sock.connect((SERVER_IP, SERVER_PORT))
    except OSError as e:
        print(f"[client] could not connect: {e}", flush=True)
        return "error"

    peer = sock.getpeername()
    myaddr = sock.getsockname()
    print(f"[client] connected {myaddr[0]}:{myaddr[1]} -> {peer[0]}:{peer[1]}", flush=True)

    # Read and parse the header.
    try:
        header = recv_exact(sock, HEADER_LEN)
    except Exception as e:
        print(f"[client] failed reading header: {e}", flush=True)
        sock.close()
        return "error"
    magic, filesize, duration_ms = struct.unpack("!4sQQ", header)
    if magic != MAGIC:
        print(f"[client] bad magic {magic!r}; aborting", flush=True)
        sock.close()
        return "error"
    duration_s = max(duration_ms / 1000.0, 0.001)
    play_bitrate = filesize / duration_s  # bytes of file per second of video
    print(f"[client] stream: {human_mb(filesize)} MB, {duration_s:.1f}s video, "
          f"playback ~{play_bitrate/1024:.0f} KB/s", flush=True)

    out = open(OUTFILE, "wb")
    received = 0
    start = time.time()
    play_start = None       # wall-clock time playback began
    last_status = 0.0
    outcome = "complete"

    # Use a short recv timeout so we can refresh the status line even when the
    # network momentarily goes quiet.
    sock.settimeout(0.5)

    def downloaded_s() -> float:
        return received / play_bitrate

    def played_s() -> float:
        if play_start is None:
            return 0.0
        return min(time.time() - play_start, downloaded_s())

    def status(tag: str = "") -> None:
        now = time.time()
        elapsed = now - start
        net_rate = received / elapsed / 1024 if elapsed > 0 else 0
        buf = downloaded_s() - played_s()
        pct = 100 * received / filesize if filesize else 0
        line = (f"[client] t={elapsed:5.1f}s  recv {human_mb(received)}/{human_mb(filesize)} MB "
                f"({pct:4.1f}%)  net {net_rate:5.0f} KB/s  buffer {buf:4.1f}s  "
                f"play {played_s():5.1f}/{duration_s:.0f}s {tag}")
        print(line, flush=True)

    try:
        while True:
            try:
                data = sock.recv(65536)
            except socket.timeout:
                # No new data this tick; still advance the status/playback view.
                if time.time() - last_status > 0.5:
                    status()
                    last_status = time.time()
                continue
            except ConnectionResetError:
                outcome = "reset"
                break
            except OSError as e:
                print(f"[client] socket error: {e}", flush=True)
                outcome = "error"
                break

            if data == b"":
                # Clean, graceful close (FIN) — normal end of stream.
                outcome = "complete"
                break

            received += len(data)
            out.write(data)

            if play_start is None and downloaded_s() >= PREBUFFER:
                play_start = time.time()
                print(f"[client] >>> playback started (prebuffered {PREBUFFER:.0f}s)", flush=True)

            if time.time() - last_status > 0.5:
                status()
                last_status = time.time()
    finally:
        out.close()
        try:
            sock.close()
        except OSError:
            pass

    # Report how the socket ended.
    if outcome == "complete":
        status("[DONE]")
        print(f"[client] ✅ stream completed gracefully (FIN). Saved {human_mb(received)} MB "
              f"to {OUTFILE}", flush=True)
        return "complete"

    if outcome == "reset":
        print("[client] " + "!" * 60, flush=True)
        print("[client] !!! TCP CONNECTION RESET (RST) received — peer sent a", flush=True)
        print("[client] !!! reset with NO preceding FIN. Socket torn down abruptly.", flush=True)
        print("[client] " + "!" * 60, flush=True)
    else:
        print("[client] stream aborted with an error.", flush=True)

    # Drain the playback buffer in real time, then stall.
    if play_start is not None:
        while played_s() < downloaded_s() - 0.05:
            status("[buffering-out]")
            time.sleep(0.5)
        status("[BUFFER EMPTY]")
    print(f"[client] ⛔ PLAYBACK STALLED — buffer exhausted, network/connection error.", flush=True)
    print(f"[client]    Received {human_mb(received)}/{human_mb(filesize)} MB before the reset.", flush=True)
    return outcome


def main() -> int:
    os.makedirs(os.path.dirname(OUTFILE) or ".", exist_ok=True)
    while True:
        result = play_session()
        if not RECONNECT:
            return 0 if result == "complete" else 2
        print(f"[client] reconnecting in {RECONNECT_DELAY:.0f}s ...\n", flush=True)
        time.sleep(RECONNECT_DELAY)


if __name__ == "__main__":
    sys.exit(main())
