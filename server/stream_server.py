#!/usr/bin/env python3
"""
stream_server.py — Custom raw-TCP video streamer.

Serves a single video file over ONE long-lived TCP connection per client
(option (a) in the design proposal, Section 1.2). This is the "victim server"
whose connection to the client is torn down by the forged RST.

Wire format sent to the client:
    [20-byte header][raw file bytes ...]
    header = 4s magic ("VSTR") | Q filesize (bytes) | Q duration (ms)

The server paces the transfer so the whole file is delivered over roughly
STREAM_SECONDS seconds. Delivering slightly faster than real-time playback
lets the client build a playback buffer, so that a mid-stream RST produces the
characteristic "stall once the buffer drains" behaviour described in the spec.
"""
import glob
import os
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time

HOST = os.environ.get("BIND_ADDR", "0.0.0.0")
PORT = int(os.environ.get("PORT", "9000"))
MEDIA = os.environ.get("MEDIA", "/media/sample.mp4")
CHUNK = int(os.environ.get("CHUNK", "16384"))
# Deliver the whole file over ~STREAM_SECONDS seconds (network pacing).
# STREAM_SECONDS controls how long the whole file takes to deliver (network
# pacing). If it is unset/blank, the server AUTO-PACES at the video's real
# duration (probed with ffprobe) so delivery matches real-time playback — no
# manual tuning. Set STREAM_SECONDS to override (smaller = faster = more buffer).
_ss_env = os.environ.get("STREAM_SECONDS", "").strip()
STREAM_SECONDS = float(_ss_env) if _ss_env else None  # None => auto from duration

MAGIC = b"VSTR"


def log(msg: str) -> None:
    print(f"[server] {msg}", flush=True)


def find_exe(name: str) -> str:
    """Locate ffprobe/ffmpeg even if not on PATH yet (stale shell after a winget
    install). Falls back to the bare name so subprocess can still try PATH."""
    p = shutil.which(name)
    if p:
        return p
    if os.name == "nt":
        local = os.environ.get("LOCALAPPDATA", "")
        for pat in (
            os.path.join(local, "Microsoft", "WinGet", "Packages", "*FFmpeg*", "**", name + ".exe"),
            os.path.join(local, "Microsoft", "WinGet", "Links", name + ".exe"),
        ):
            try:
                hits = glob.glob(pat, recursive=True)
            except Exception:
                hits = []
            if hits:
                return hits[0]
    return name


def probe_duration_ms(path: str) -> int:
    """Return media duration in ms via ffprobe, or 0 if unavailable."""
    try:
        out = subprocess.check_output(
            [
                find_exe("ffprobe"), "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                path,
            ],
            stderr=subprocess.DEVNULL,
        )
        return int(float(out.strip()) * 1000)
    except Exception:
        return 0


def handle_client(conn: socket.socket, addr, filesize: int, duration_ms: int) -> None:
    peer = f"{addr[0]}:{addr[1]}"
    log(f"client connected: {peer}")
    # Bytes/sec so the transfer takes ~STREAM_SECONDS.
    rate = max(filesize / STREAM_SECONDS, 1.0)
    sleep_per_chunk = CHUNK / rate
    sent = 0
    start = time.time()
    try:
        # Send the header first.
        conn.sendall(MAGIC + struct.pack("!QQ", filesize, duration_ms))
        with open(MEDIA, "rb") as f:
            next_deadline = time.time()
            while True:
                data = f.read(CHUNK)
                if not data:
                    break
                conn.sendall(data)
                sent += len(data)
                # Pace the stream to the target rate.
                next_deadline += sleep_per_chunk
                delay = next_deadline - time.time()
                if delay > 0:
                    time.sleep(delay)
        elapsed = time.time() - start
        log(f"stream to {peer} completed: {sent} bytes in {elapsed:.1f}s")
    except (ConnectionResetError, BrokenPipeError) as e:
        elapsed = time.time() - start
        log(f"connection to {peer} RESET/broken after {sent} bytes, {elapsed:.1f}s ({e})")
    except Exception as e:
        log(f"error serving {peer}: {e}")
    finally:
        try:
            conn.close()
        except OSError:
            pass


def main() -> int:
    if not os.path.exists(MEDIA):
        log(f"FATAL: media file not found: {MEDIA}")
        return 1
    filesize = os.path.getsize(MEDIA)
    duration_ms = probe_duration_ms(MEDIA)

    # Auto-pace at the real video duration unless STREAM_SECONDS was set.
    global STREAM_SECONDS
    if STREAM_SECONDS is None:
        if duration_ms > 0:
            STREAM_SECONDS = duration_ms / 1000.0
            log(f"auto-pacing at the video's real duration ~{STREAM_SECONDS:.0f}s "
                f"(set STREAM_SECONDS to override)")
        else:
            STREAM_SECONDS = 60.0
            log(f"duration unknown (no ffprobe?); defaulting pace to {STREAM_SECONDS:.0f}s "
                f"(set STREAM_SECONDS to override)")

    if duration_ms == 0:
        # Fallback: assume the network pacing rate equals the playback rate.
        duration_ms = int(STREAM_SECONDS * 1000)
    log(f"media={MEDIA} size={filesize} bytes duration={duration_ms/1000:.1f}s")
    log(f"pacing whole file over ~{STREAM_SECONDS:.0f}s "
        f"(~{filesize/STREAM_SECONDS/1024:.0f} KB/s)")

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(8)
    log(f"listening on {HOST}:{PORT}")

    try:
        while True:
            conn, addr = srv.accept()
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            t = threading.Thread(
                target=handle_client,
                args=(conn, addr, filesize, duration_ms),
                daemon=True,
            )
            t.start()
    except KeyboardInterrupt:
        log("shutting down")
    finally:
        srv.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
