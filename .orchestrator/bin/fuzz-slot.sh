#!/bin/bash
# Acquire the machine-wide fuzz slot (FIFO-fair), then run one wave.
#
# Fuzzing is globally serialized: exactly ONE wave runs anywhere on the machine at a time, one
# harness per core in FUZZ_CORES (default "0 1 2 3"). Everything else -- builds, ESBMC, TLC --
# goes through heavy-slot.sh on HEAVY_CPUS (default 4-7).
#
# flock alone is NOT fair on Linux: with 30-minute waves and 3 contenders an unlucky agent can
# starve for hours. The ticket directory below adds FIFO ordering on top; flock still provides
# the actual mutual exclusion. flock is kernel-released on holder death, so a killed agent
# cannot wedge the box, and stale tickets age out after 90 minutes.
#
# Usage:
#   AGENT_NAME=<proj> fuzz-slot.sh <build-fuzz-dir> <triage|graded> <harness>...
#
# Exit codes propagate from run_wave.sh: 0 ok, 3 WAVE INVALID (re-run), 77 finding to triage.
set -eu

ORCH="${AUDIT_ORCH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
AGENT="${AGENT_NAME:-unknown}"
QD="$ORCH/fuzzq"
mkdir -p "$QD"

TICKET="$(date +%s)-$$-$AGENT"
: > "$QD/$TICKET"
cleanup() { rm -f "$QD/$TICKET"; }
trap cleanup EXIT INT TERM

echo "[fuzz-slot] queued as $TICKET"

# Wait until we are the oldest LIVE ticket. Tickets older than 90 min are treated as belonging
# to a dead agent and ignored, so a crash cannot wedge the queue.
waited=0
while :; do
    head_ticket="$(find "$QD" -type f -mmin -90 -printf '%f\n' 2>/dev/null \
                   | sort -t- -k1,1n | head -1)"
    [ -z "$head_ticket" ] && break
    [ "$head_ticket" = "$TICKET" ] && break
    if [ "$((waited % 300))" -eq 0 ]; then
        echo "[fuzz-slot] waiting behind $head_ticket (${waited}s)"
    fi
    sleep 30
    waited=$((waited + 30))
done

echo "[fuzz-slot] acquiring fuzz.lock after ${waited}s in queue"
flock -w 7200 "$ORCH/fuzz.lock" "$ORCH/bin/run_wave.sh" "$@"
