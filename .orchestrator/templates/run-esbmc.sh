#!/bin/bash
# TEMPLATE -- copy into <project>-verified/formal/esbmc/ and adapt REPO_ROOT, INCS, run_tier1().
#
# Standalone driver for this directory's ESBMC harnesses. Deliberately NOT wired into
# CMake/ctest -- ESBMC uses its own embedded frontend and never touches the project's real
# toolchain, so making this part of the normal build graph would misleadingly imply
# "green build => ESBMC-verified." Run by hand: ./run-esbmc.sh [tier1|all] (default: all).
#
# ESBMC binary, first found of: $ESBMC; $AUDIT_ROOT/esbmc/build/src/esbmc/esbmc;
# ../../../esbmc/build/src/esbmc/esbmc (an esbmc/ checkout beside the fork); `esbmc` on PATH.
# Developed against v8.4.0. Treat a source checkout as READ-ONLY: never rebuild it mid-audit.
#
# TWO DESIGN POINTS THAT ARE EASY TO UNDO BY ACCIDENT:
#
# 1. ESBMC_LOG is per-directory, never a shared path such as /tmp/esbmc_last_run.log. With
#    several agents auditing different projects concurrently, a global path lets agent B
#    overwrite the log between agent A's run finishing and A reading it -- so the
#    "FAIL: ... (see ...)" message points at another project's output. Silent, and the wrong
#    diagnostic looks entirely plausible.
#
# 2. Every invocation goes through heavy-slot.sh, which serializes builds/ESBMC/TLC
#    machine-wide on HEAVY_CPUS and bounds them. ESBMC peaked at 1266MB on a hard-but-
#    completing run in practice, so --memlimit 1500m is sized above that: 1200m would abort work
#    that legitimately finishes. Set ESBMC_DIRECT=1 to bypass the lock (single-agent use).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ -z "${ESBMC:-}" ]; then
    for cand in "${AUDIT_ROOT:+$AUDIT_ROOT/esbmc/build/src/esbmc/esbmc}" \
                ../../../esbmc/build/src/esbmc/esbmc "$(command -v esbmc 2>/dev/null || true)"; do
        if [ -n "$cand" ] && [ -x "$cand" ]; then ESBMC="$cand"; break; fi
    done
fi
ESBMC="${ESBMC:-esbmc}"
ESBMC_LOG="${ESBMC_LOG:-$SCRIPT_DIR/last_run.log}"
# Machine-wide heavy-slot serialization. Required when several audits share one box; optional
# when you are the only one on it. Set AUDIT_ORCH to this repository's .orchestrator/ to enable it.
# If the slot script is not found we fall back to running ESBMC directly and say so once --
# correct for a solo researcher, and loud enough that nobody silently loses serialization on a
# shared machine.
HEAVY="${AUDIT_ORCH:+$AUDIT_ORCH/bin/heavy-slot.sh}"
if [ -z "${HEAVY:-}" ] || [ ! -x "$HEAVY" ]; then
    echo "note: no heavy-slot found (AUDIT_ORCH unset or not executable) -- running ESBMC" \
         "directly, without machine-wide serialization." >&2
    HEAVY=""
fi
REPO_ROOT="../.."          # ADAPT: path from formal/esbmc/ to the library source root

if [ ! -x "$ESBMC" ]; then
    echo "esbmc binary not found/executable at $ESBMC (set ESBMC=... to override)" >&2
    exit 1
fi

# ADAPT: include paths for this project
INCS="-I $REPO_ROOT/src"

PASS=0
FAIL=0

# Wrap one ESBMC invocation in the machine-wide heavy slot unless ESBMC_DIRECT=1.
esbmc_run() {
    if [ "${ESBMC_DIRECT:-0}" = "1" ]; then
        "$ESBMC" "$@" $INCS --memlimit 1500m --timeout 600 2>&1
    else
        "$HEAVY" 660 "$ESBMC" "$@" $INCS --memlimit 1500m --timeout 600 2>&1
    fi
}

run_one() {
    local desc="$1"; shift
    echo "--- $desc ---"
    if esbmc_run "$@" | tee "$ESBMC_LOG" | tail -3 | grep -q "VERIFICATION SUCCESSFUL"; then
        echo "PASS: $desc"
        PASS=$((PASS+1))
    else
        # rc=124 from the outer timeout, or an ESBMC --timeout hit, is reported as
        # "NOT PROVEN -- timed out", which is an honest result. Never widen the bound to
        # force a green; record the intractability instead.
        echo "FAIL: $desc (see $ESBMC_LOG)"
        FAIL=$((FAIL+1))
    fi
    echo
}

run_tier1() {
    # ADAPT: one run_one per harness. Size --unwind at (largest true iteration count) + 1,
    # INCLUDING the harness's own fill loops. Never pass --no-unwinding-assertions: combined
    # with an insufficient bound it produces a silent false VERIFICATION SUCCESSFUL.
    :
    # run_one "some_decoder_getFromBuffer" \
    #     tier1_parsing/esbmc_some_decoder.c \
    #     "$REPO_ROOT/src/some_decoder.c" \
    #     --unwind 9 --overflow-check --memory-leak-check
}

scope="${1:-all}"
case "$scope" in
    tier1) run_tier1 ;;
    all)   run_tier1 ;;
    *) echo "usage: $0 [tier1|all]" >&2; exit 1 ;;
esac

echo "===================="
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
