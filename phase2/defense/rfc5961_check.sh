#!/usr/bin/env bash
# rfc5961_check.sh — verify/explain the PRIMARY (TCP-layer) defense (proposal §6.1).
#
# RFC 5961 ("Improving TCP's Robustness to Blind In-Window Attacks") tightens RST
# handling: an incoming RST is accepted immediately ONLY if its sequence number
# equals RCV.NXT *exactly*; an in-window-but-not-exact RST triggers a challenge
# ACK instead of a teardown. Modern Linux implements this unconditionally, so it
# is the always-on baseline defense against a BLIND/off-path attacker.
#
# It does NOT stop our ON-PATH attacker — that host reads the exact RCV.NXT off
# the wire and so meets the exact-match rule. That contrast is the point of §6.1:
# RFC 5961 raises the bar enormously for off-path attackers but must be paired
# with the ARP-layer defense (§6.2, static_arp/defend) to stop an on-path one.
#
# Run on the LINUX victim (client or server). Read-only; no root needed.
set -euo pipefail

echo "== RFC 5961 (TCP-layer, primary defense §6.1) =="
echo "kernel: $(uname -sr)"
echo

# The challenge-ACK mechanism is the observable RFC 5961 knob on Linux.
CAL="/proc/sys/net/ipv4/tcp_challenge_ack_limit"
if [ -r "$CAL" ]; then
    echo "net.ipv4.tcp_challenge_ack_limit = $(cat "$CAL")"
    echo "  -> present => this kernel implements RFC 5961 challenge ACKs."
    echo "     (A high/large value is normal on modern kernels; the exact-match"
    echo "      RST rule itself is unconditional and cannot be turned off.)"
else
    echo "tcp_challenge_ack_limit not found — very old kernel; RFC 5961 may be absent."
fi
echo

# Other related hardening sysctls, for completeness.
for k in net.ipv4.tcp_rfc1337 net.ipv4.tcp_syncookies net.ipv4.conf.all.rp_filter; do
    v="$(sysctl -n "$k" 2>/dev/null || echo '?')"
    printf '  %-32s = %s\n' "$k" "$v"
done
echo

cat <<'EOF'
Interpretation for this project
  * BLIND / off-path attacker  : RFC 5961 makes a forged RST land only on an exact
    RCV.NXT guess (1-in-2^32-ish) -> in-window guesses draw a challenge ACK, not a
    reset. The attack is effectively defeated at the TCP layer alone.
  * ON-PATH attacker (ours)    : reads the live RCV.NXT via the ARP-poison MITM, so
    it satisfies the exact-match rule and RFC 5961 does NOT stop it.
  => Combine with the ARP-layer defense (defend.sh / static_arp) to remove the
     on-path position; then the attacker is reduced to the blind case above.

Show it directly (contrast, spec Table 2 "success with vs. without defense"):
  1) No MITM  -> run rst_attack.py WITHOUT arp_spoof.py: it never sees RCV.NXT;
                 any in-window RST only draws challenge ACKs (RFC 5961 holds).
  2) MITM     -> with arp_spoof.py the exact match is read off the wire and the
                 RST lands -> proving §6.1 alone is insufficient on-path.
  3) MITM + ARP defense (defend.sh on the victims) -> MITM cannot form, back to (1).
EOF
