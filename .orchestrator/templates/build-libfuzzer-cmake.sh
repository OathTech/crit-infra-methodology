#!/bin/bash
# TEMPLATE (CMake projects) -- copy into <project>-verified/fuzz/ and adapt LIB_DIR, the cmake
# line, the target name, INCS, and the link line. For autotools/direct-compile projects, keep the
# two-step shape and the instrumentation gate below, and replace only the library build step.
#
# Builds every fuzz/*.c harness against an ASan+UBSan-instrumented static archive. Two-step:
# (1) configure+build the library with sanitizer flags via CMake, (2) compile each harness
# directly against that archive with -fsanitize=...,fuzzer added on top (libFuzzer's own
# main(), not CMake's).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$REPO_ROOT"                      # ADAPT if the library lives in a subdirectory
BUILD_DIR="$LIB_DIR/build-fuzz"

SAN="-fsanitize=address,undefined -fno-sanitize=function -fno-sanitize-recover=all -g -O1"

# -fsanitize=fuzzer-no-link adds SanitizerCoverage instrumentation (the inline 8-bit counters /
# PC tables libFuzzer uses for coverage-guided mutation) WITHOUT pulling in libFuzzer's own
# main()/runtime -- needed so coverage feedback reflects the LIBRARY's real decode functions,
# not just the harness wrapper. Omitting this from the library build silently produces a binary
# that "runs" fine but whose counters only ever track the outer harness: ASan still catches
# crashes, so nothing looks wrong, while every reported cov: number is meaningless. This
# happened TWICE in prior audits. The instrumentation gate below is non-negotiable.
LIB_SAN="$SAN -fsanitize=fuzzer-no-link"
HARNESS_SAN="$SAN -fsanitize=fuzzer"

# BUILD_JOBS, not $(nproc): with three agents on an 8-core box, -j$(nproc) each means 24
# concurrent ASan clang processes. CMAKE_BUILD_PARALLEL_LEVEL will NOT help here -- an
# explicit -j on the command line overrides it.
JOBS="${BUILD_JOBS:-4}"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

cmake .. -DCMAKE_BUILD_TYPE=Debug -DCMAKE_C_COMPILER=clang \
    -DCMAKE_C_FLAGS="$LIB_SAN"            # ADAPT: add -DBUILD_EXAMPLES=OFF -DBUILD_TESTS=OFF etc.
cmake --build . --target "${LIB_TARGET:?set LIB_TARGET to the library target name}" -j"$JOBS"

mkdir -p bin corpus campaign

INCS="-I$LIB_DIR/include"                 # ADAPT
ARCHIVE="$BUILD_DIR/lib${LIB_TARGET}.a"   # ADAPT if CMake puts it elsewhere

for harness in "$SCRIPT_DIR"/fuzz_*.c; do
    [ -e "$harness" ] || continue
    name="$(basename "$harness" .c)"
    echo "--- building $name ---"
    clang $HARNESS_SAN $INCS -o "bin/$name" "$harness" "$ARCHIVE" -lpthread -lm
    mkdir -p "corpus/$name"
done

# ---------------------------------------------------------------------------
# INSTRUMENTATION GATE (blocking -- no campaign number is trustworthy without it)
# ---------------------------------------------------------------------------
echo
echo "=== instrumentation gate ==="
# TWO independent checks, because `nm | grep __sancov_gen` alone produces FALSE NEGATIVES.
# Clang emits the named __sancov_gen* symbols only in some contexts (notably functions with
# switch value tables); a small or switch-free translation unit can be fully instrumented and
# still show zero. That was hit for real on a tiny, switch-free TU. The authoritative check is
# the presence of the __sancov_cntrs / __sancov_pcs SECTIONS and the module constructor that
# registers them -- those exist in every instrumented object regardless of symbol naming.
sancov_count="$(nm "$ARCHIVE" 2>/dev/null | grep -c __sancov_gen || true)"
sancov_sections="$(objdump -h "$ARCHIVE" 2>/dev/null | grep -cE '__sancov_cntrs|__sancov_pcs' || true)"
echo "__sancov_gen symbols in $(basename "$ARCHIVE"): $sancov_count"
echo "__sancov_cntrs/__sancov_pcs sections:          $sancov_sections"
if [ "${sancov_count:-0}" -eq 0 ] && [ "${sancov_sections:-0}" -eq 0 ]; then
    echo "GATE FAIL: library has no SanitizerCoverage instrumentation by either check." >&2
    echo "  Coverage feedback would be blind and every cov: number meaningless." >&2
    echo "  Check that LIB_SAN (with -fsanitize=fuzzer-no-link) reached the library build." >&2
    exit 1
fi
if [ "${sancov_count:-0}" -eq 0 ]; then
    echo "NOTE: __sancov_gen count is 0 but sancov SECTIONS are present -- instrumented."
    echo "      Record both numbers, and lean on the runtime counter ratio below."
fi

first="$(ls bin/ 2>/dev/null | head -1 || true)"
if [ -n "$first" ]; then
    counters="$(./bin/"$first" -runs=0 2>&1 | grep -oE '\([0-9]+ inline 8-bit counters\)' \
                | grep -oE '[0-9]+' | head -1 || true)"
    echo "inline 8-bit counters loaded by $first: ${counters:-unknown}"
    if [ -n "$counters" ] && [ "$counters" -lt 200 ]; then
        echo "GATE WARN: only $counters counters -- expected >=200 unless the library is tiny." >&2
        echo "  Compare against a harness-only baseline before trusting any campaign." >&2
    fi
fi
echo "Record BOTH numbers verbatim in VERIFICATION.md before reporting any campaign result."

echo
echo "Done. Binaries in $BUILD_DIR/bin/. Run waves through the machine-wide slot:"
echo "  AGENT_NAME=<proj> $AUDIT_ORCH/bin/fuzz-slot.sh \\"
echo "      $BUILD_DIR triage  <harness>..."
echo "  AGENT_NAME=<proj> $AUDIT_ORCH/bin/fuzz-slot.sh \\"
echo "      $BUILD_DIR graded  <harness>..."
