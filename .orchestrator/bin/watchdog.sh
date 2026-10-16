#!/bin/bash
# Memory / thrash watchdog. Appends one line per minute to .orchestrator/watchdog.log
#
# Written for a container with NO cgroups and an unreadable dmesg, where kernel OOM kills cannot
# be observed directly -- they are inferred from exit codes in run_wave.sh. This watchdog is the
# early-warning half: it catches the pressure BEFORE the kill, so an in-flight wave can be
# marked suspect.
#
# Thresholds:
#   MemAvailable < 500MB for 3 consecutive samples -> kill the heavy.lock holder, never the
#     fuzz wave (killing the wave wastes 30 min of the scarcest resource; heavy work is cheap
#     to redo).
#   Swap used > 400MB (reference box: 1024MB of swap), or sustained swap-in/out -> the box is thrashing and any
#     fuzz wave in flight is already invalid; its numbers are not comparable.
set -u
ORCH="${AUDIT_ORCH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG="$ORCH/watchdog.log"
low_streak=0

while :; do
    avail="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)"
    swapu="$(awk '/SwapFree/{f=$2} /SwapTotal/{t=$2} END{print int((t-f)/1024)}' /proc/meminfo)"
    # Bracket trick: the pattern '[b]in/fuzz_' does not match this script's own command
    # line (which literally contains the brackets), so the count is not inflated by self-match.
    fz="$(pgrep -cf '[b]in/fuzz_' 2>/dev/null || true)"

    flags=""
    if [ "$avail" -lt 500 ]; then
        low_streak=$((low_streak + 1))
        flags="$flags LOW-MEM(${low_streak})"
    else
        low_streak=0
    fi
    [ "$swapu" -gt 400 ] && flags="$flags SWAPPING"
    [ "$low_streak" -ge 3 ] && flags="$flags ACTION:kill-heavy-holder"

    printf '%s avail=%sMB swap_used=%sMB fuzzers=%s%s\n' \
        "$(date -u +%FT%TZ)" "$avail" "$swapu" "${fz:-0}" "$flags" >> "$LOG"
    sleep 60
done
