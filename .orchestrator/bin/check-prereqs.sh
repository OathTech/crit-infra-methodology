#!/bin/bash
# Check that this machine can run an audit, and say in plain words what is missing.
#
# Usage: check-prereqs.sh
#
# Safe to run any time: it installs nothing and writes only to a temporary directory, which it
# removes. Exit 0 means every REQUIRED item passed; OPTIONAL items (TLA+) only warn.
#
# The libFuzzer check compiles and runs a two-line fuzzer rather than just looking for clang:
# many distributions ship clang without the fuzzer/sanitizer runtime, and that only shows up as
# a link error. Checking the real thing is the only check that does not lie.
set -u

ORCH="${AUDIT_ORCH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ROOT="${AUDIT_ROOT:-$(cd "$ORCH/.." && pwd)}"

fail=0
ok()   { printf '  [ok]      %s\n' "$1"; }
bad()  { printf '  [MISSING] %s\n            -> %s\n' "$1" "$2"; fail=1; }
warn() { printf '  [warn]    %s\n            -> %s\n' "$1" "$2"; }

echo "== Operating system"
if [ "$(uname -s)" = "Linux" ]; then
    ok "Linux ($(uname -m))"
else
    bad "Linux" "run this inside a Linux machine or a Linux-based Docker container"
fi

echo "== Basic tools"
for c in git curl jq make cmake flock taskset timeout; do
    if command -v "$c" >/dev/null 2>&1; then ok "$c"; else
        bad "$c" "install the package that provides '$c' (flock/taskset: util-linux; timeout: coreutils)"
    fi
done

echo "== clang with libFuzzer, AddressSanitizer and UndefinedBehaviorSanitizer"
if ! command -v clang >/dev/null 2>&1; then
    bad "clang" "install clang and its compiler-rt runtime (on Debian/Ubuntu: clang and libclang-rt-dev)"
else
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    cat > "$tmp/f.c" <<'EOF'
#include <stdint.h>
#include <stddef.h>
int LLVMFuzzerTestOneInput(const uint8_t *d, size_t n) { (void)d; (void)n; return 0; }
EOF
    if clang -fsanitize=fuzzer,address,undefined -o "$tmp/f" "$tmp/f.c" >"$tmp/log" 2>&1 \
       && "$tmp/f" -runs=10 >>"$tmp/log" 2>&1; then
        ok "clang $(clang -dumpversion) builds and runs a sanitized fuzzer"
    else
        bad "clang fuzzer/sanitizer runtime" \
            "clang is present but cannot build a fuzzer; install compiler-rt (on Debian/Ubuntu: libclang-rt-dev). Error: $(head -1 "$tmp/log")"
    fi
fi

echo "== ESBMC (bounded model checker)"
esbmc_bin=""
for cand in "${ESBMC:-}" "$ROOT/esbmc/build/src/esbmc/esbmc" "$(command -v esbmc 2>/dev/null || true)"; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then esbmc_bin="$cand"; break; fi
done
if [ -n "$esbmc_bin" ]; then
    ok "$("$esbmc_bin" --version 2>&1 | head -1) at $esbmc_bin"
else
    bad "esbmc" "install ESBMC (https://github.com/esbmc/esbmc): a release binary on your PATH, or build it into $ROOT/esbmc/, or set ESBMC=/path/to/esbmc"
fi

echo "== TLA+ (optional, only for Phase 6 protocol models)"
if command -v java >/dev/null 2>&1; then ok "java"; else
    warn "java" "install a Java runtime (on Debian/Ubuntu: default-jre-headless)"
fi
if [ -f "$ROOT/formal-tools/tla2tools.jar" ]; then ok "tla2tools.jar"; else
    warn "tla2tools.jar" "download it from https://github.com/tlaplus/tlaplus/releases into $ROOT/formal-tools/"
fi

echo "== Settings"
if [ -n "${AUDIT_ROOT:-}" ] && [ -n "${AUDIT_ORCH:-}" ]; then
    ok "AUDIT_ROOT=$AUDIT_ROOT, AUDIT_ORCH=$AUDIT_ORCH"
else
    bad "AUDIT_ROOT / AUDIT_ORCH" "add to your shell profile: export AUDIT_ROOT=\"$ROOT\"; export AUDIT_ORCH=\"$ORCH\""
fi
cores="$(nproc)"; mem="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
if [ "$cores" -ge 8 ] && [ -z "${FUZZ_CORES:-}${HEAVY_CPUS:-}" ]; then
    ok "$cores cores, ${mem} MB RAM (defaults: fuzz on cores 0-3, heavy work on 4-7)"
elif [ -n "${FUZZ_CORES:-}" ] && [ -n "${HEAVY_CPUS:-}" ]; then
    ok "$cores cores, ${mem} MB RAM, FUZZ_CORES=\"$FUZZ_CORES\", HEAVY_CPUS=$HEAVY_CPUS"
else
    bad "core layout" "this machine has $cores cores; the defaults need 8. Set FUZZ_CORES and HEAVY_CPUS to two disjoint sets, e.g. FUZZ_CORES=\"0 1\" HEAVY_CPUS=2-3 on 4 cores"
fi
[ "$mem" -lt 6000 ] && warn "memory: ${mem} MB" "6 GB or more is recommended; run one audit at a time"

echo
if [ "$fail" -eq 0 ]; then echo "Ready: all required prerequisites are in place."; else
    echo "Not ready: fix the MISSING items above, then run this again."; fi
exit "$fail"
