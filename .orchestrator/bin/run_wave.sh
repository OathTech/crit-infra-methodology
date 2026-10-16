#!/bin/bash
# Run ONE fuzz wave: one harness per core listed in FUZZ_CORES (default "0 1 2 3"), each pinned
# to its own core. The wave is capped at the number of cores listed.
#
# This script assumes the caller already holds fuzz.lock -- do not invoke it directly.
# Go through fuzz-slot.sh, which handles FIFO fairness and the lock.
#
# Usage: run_wave.sh <build-fuzz-dir> <triage|graded> <harness>...
#
# Wave-invalidation rule: if any harness is kernel-OOM-killed (rc=137 with no libFuzzer
# banner) or leaves no "Done N runs" line, the WHOLE wave is invalid and must be re-run --
# the survivors' throughput was depressed by the same memory starvation, so their coverage
# numbers are not comparable to any other campaign. Exit 3 signals that.
set -u

BUILD_DIR="${1:?usage: run_wave.sh <build-fuzz-dir> <triage|graded> <harness>...}"; shift
MODE="${1:?mode must be triage or graded}"; shift

case "$MODE" in
    triage) MAXT=120;  OUTER=180  ;;
    graded) MAXT=1800; OUTER=2100 ;;
    *) echo "mode must be 'triage' or 'graded', got '$MODE'" >&2; exit 2 ;;
esac

read -r -a CORES <<< "${FUZZ_CORES:-0 1 2 3}"
NCORES="${#CORES[@]}"
[ "$NCORES" -gt 0 ] || { echo "FUZZ_CORES is empty" >&2; exit 2; }

cd "$BUILD_DIR" || { echo "no such build dir: $BUILD_DIR" >&2; exit 2; }
mkdir -p bin corpus campaign

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
STATUS="campaign/wave-${MODE}-${STAMP}.status"
: > "$STATUS"

# Sweep orphaned fuzzers from a previously killed agent. Safe: we hold fuzz.lock, so no
# legitimate wave can be running anywhere on the box.
#
# The '[f]uzz_' bracket trick is load-bearing, not cosmetic: a plain "bin/fuzz_" pattern also
# matches the command line of any shell that was invoked WITH that string in its arguments --
# including this script's own wrapper -- so pkill could terminate its own parent. The bracketed
# form matches the target processes but never the literal pattern text in a caller's cmdline.
pkill -f "$BUILD_DIR/bin/[f]uzz_" 2>/dev/null || true

i=0; pids=(); names=(); logs=()
for name in "$@"; do
    if [ "$i" -ge "$NCORES" ]; then
        echo "wave capped at $NCORES harnesses (FUZZ_CORES); skipping '$name'" | tee -a "$STATUS" >&2
        continue
    fi
    if [ ! -x "bin/$name" ]; then
        echo "$name rc=- verdict=MISSING-BINARY" | tee -a "$STATUS" >&2
        continue
    fi
    mkdir -p "corpus/$name"
    log="campaign/${name}-${MODE}-${STAMP}.log"
    # taskset pins one harness per core so they cannot steal from each other; everything else
    # on the box is confined to HEAVY_CPUS. This is what protects exec/s under contention.
    ( cd bin && taskset -c "${CORES[$i]}" timeout -k 30 "$OUTER" ./"$name" \
        -max_total_time="$MAXT" -rss_limit_mb=1200 -close_fd_mask=3 \
        -timeout=25 -print_final_stats=1 -error_exitcode=77 \
        -artifact_prefix="../campaign/crash-${name}-" \
        "../corpus/$name/" > "../$log" 2>&1 ) &
    pids+=("$!"); names+=("$name"); logs+=("$log"); i=$((i+1))
done

if [ "${#pids[@]}" -eq 0 ]; then
    echo "no harnesses started" >&2
    exit 2
fi

invalid=0
findings=0
for idx in "${!pids[@]}"; do
    if wait "${pids[$idx]}"; then rc=0; else rc=$?; fi
    n="${names[$idx]}"; log="${logs[$idx]}"

    # Finding detection must cover THREE shapes, not just libFuzzer's own banner:
    #   1. libFuzzer banners  -- deadly signal / OOM / timeout
    #   2. sanitizer SUMMARY  -- an ASan or UBSan abort under -fno-sanitize-recover=all often
    #      terminates the process WITHOUT libFuzzer printing a banner of its own. A real
    #      UBSan-only finding was misclassified as NO-COMPLETION -> WAVE INVALID by an earlier
    #      version of this check, which would have discarded a genuine bug and burned a slot
    #      re-running a wave that was never starved.
    #   3. "Test unit written to" -- libFuzzer persisted a crash artifact, which by itself is
    #      conclusive evidence of a finding regardless of which runtime reported it.
    banner="$(grep -m1 -oE 'ERROR: libFuzzer: (deadly signal|out-of-memory|timeout)' "$log" 2>/dev/null || true)"
    if [ -z "$banner" ]; then
        banner="$(grep -m1 -oE 'SUMMARY: (Address|Undefined[A-Za-z]*|Memory|Thread|Leak)Sanitizer[a-z: -]*' "$log" 2>/dev/null || true)"
    fi
    if [ -z "$banner" ] && grep -q 'Test unit written to' "$log" 2>/dev/null; then
        banner="crash artifact written"
    fi
    done_line="$(grep -cE '^Done [0-9]+ runs in' "$log" 2>/dev/null || true)"
    execs="$(grep -oE 'stat::number_of_executed_units:[[:space:]]*[0-9]+' "$log" 2>/dev/null | tail -1 | grep -oE '[0-9]+$' || true)"
    execps="$(grep -oE 'stat::average_exec_per_sec:[[:space:]]*[0-9]+' "$log" 2>/dev/null | tail -1 | grep -oE '[0-9]+$' || true)"
    cov="$(grep -oE 'cov: [0-9]+ ft: [0-9]+' "$log" 2>/dev/null | tail -1 || true)"

    verdict=OK
    if [ -n "$banner" ]; then
        verdict="FINDING(${banner##*libFuzzer: })"
        findings=$((findings+1))
    elif [ "$rc" = "137" ]; then
        verdict=KERNEL-OOM; invalid=1
    elif [ "${done_line:-0}" = "0" ]; then
        verdict=NO-COMPLETION; invalid=1
    elif [ "$rc" = "124" ]; then
        verdict=OUTER-TIMEOUT; invalid=1
    fi

    printf '%s rc=%s verdict=%s execs=%s exec_per_sec=%s %s log=%s\n' \
        "$n" "$rc" "$verdict" "${execs:-?}" "${execps:-?}" "${cov:-cov:?}" "$log" \
        | tee -a "$STATUS"
done

echo "---" | tee -a "$STATUS"
if [ "$invalid" = "1" ]; then
    echo "WAVE INVALID -- memory starvation suspected; re-run this wave, do not report its numbers" \
        | tee -a "$STATUS"
    exit 3
fi
if [ "$findings" -gt 0 ]; then
    echo "wave OK, $findings harness(es) reported a finding -- triage per SEV-STOP before continuing" \
        | tee -a "$STATUS"
    exit 77
fi
echo "wave OK (mode=$MODE): $STATUS" | tee -a "$STATUS"
