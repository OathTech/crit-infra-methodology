#!/bin/bash
# Serialize ONE heavy task machine-wide: a build, an ESBMC run, or a TLC run.
# Pinned to HEAVY_CPUS (default 4-7) at nice 10 so it can never contend with an in-flight fuzz
# wave (FUZZ_CORES, default 0-3), and bounded by an outer timeout so nothing outlives its budget.
# The defaults suit the reference 8-core box; set both variables to match yours, keeping the
# two core sets disjoint.
#
# Usage: heavy-slot.sh <timeout-secs> <command>...
#
# Examples:
#   heavy-slot.sh 3600 env BUILD_JOBS=4 ./fuzz/build-libfuzzer.sh
#
#   heavy-slot.sh 660 "$ESBMC" formal/esbmc/tier1_parsing/esbmc_foo.c src/foo.c \
#       --unwind 12 --overflow-check --memory-leak-check --memlimit 1500m --timeout 600
#
#   heavy-slot.sh 1800 java -Xmx1g -XX:+UseSerialGC \
#       -cp "$AUDIT_ROOT/formal-tools/tla2tools.jar" tlc2.TLC -workers 2 Spec.tla
#
# ESBMC note: pass BOTH --memlimit 1500m and --timeout 600 so ESBMC self-terminates with a
# real verdict; the outer timeout here is only a backstop for when its SIGALRM watchdog is
# missed by a solver in a tight loop. rc=124 means the backstop fired -- record that as
# "NOT PROVEN -- timed out at <N>s at --unwind <N>", which is an honest result, not a failure.
#
# Never wrap an ASan-instrumented binary in ulimit -v / prlimit --as: ASan reserves ~20TB of
# virtual address space and will abort at startup. Use libFuzzer's -rss_limit_mb instead.
set -eu

ORCH="${AUDIT_ORCH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
T="${1:?usage: heavy-slot.sh <timeout-secs> <command>...}"; shift

HEAVY_CPUS="${HEAVY_CPUS:-4-7}"

exec flock -w 3600 "$ORCH/heavy.lock" \
    timeout -k 30 "$T" nice -n 10 taskset -c "$HEAVY_CPUS" "$@"
