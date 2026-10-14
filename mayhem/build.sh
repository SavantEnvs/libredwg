#!/usr/bin/env bash
#
# mayhem/build.sh — build LibreDWG's llvmfuzz harness (libFuzzer + standalone) AND its unit-test
# suite. Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem == $SRC.
#
# Layout produced:
#   /mayhem/llvmfuzz              libFuzzer target (SanitizerCoverage + ASan/UBSan)   <- the Mayhem target
#   /mayhem/llvmfuzz-standalone   run-once file-input reproducer (same code path)
#   $SRC/build-tests/...          the project's unit tests, built with NORMAL flags for mayhem/test.sh
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# Parallelism is bounded by MEMORY, not by core count.  LibreDWG's generated TUs (src/encode2.c,
# src/out_json.c, src/in_dxf.c) each need ~2.6 GB of clang under ASan+UBSan+SanitizerCoverage --
# measured, not guessed: a single `make out_json.lo` in this image peaks at 2,648 MB RSS -- and a
# plain `-j$(nproc)` on a many-core builder launches that many at once: on a 128-core host the build
# is OOM-killed ("libtool: line 1904: Killed  clang ... -c ../../src/encode2.c") inside any cgroup
# smaller than ~128 GB.  That is not hypothetical -- verify-repo.sh runs every container at
# VERIFY_DOCKER_MEM (8g, --memory-swap equal so there is no swap to fall back on), sized against the
# real analyze-node budget, and the docker BUILD does not hit it only because BuildKit doesn't apply
# --memory to RUN steps.  Cap the job count so the build fits the budget it will actually run in:
# 3 GB per job covers the 2.6 GB peak with headroom for make/libtool, so the gate's 8g container
# gets -j2 and an unconstrained host still gets one job per core.  MAYHEM_JOBS from the environment
# still wins, so CI or a bigger analyze node can raise it.
# Read the CGROUP budget, not /proc/meminfo -- inside a container the latter reports the host's
# RAM (503 GB here) and would defeat the whole point.  cgroup v2 first, then v1; "max" or a missing
# file means unlimited, in which case fall back to the host total.
_mem_bytes=""
for _f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
  [ -r "$_f" ] || continue
  _v=$(cat "$_f" 2>/dev/null)
  case "$_v" in ''|max|[!0-9]*) continue ;; esac
  # cgroup v1 reports a sentinel near 2^63 when unlimited
  [ "$_v" -ge 9223372036854000000 ] 2>/dev/null && continue
  _mem_bytes="$_v"; break
done
if [ -z "$_mem_bytes" ]; then
  _mem_bytes=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0) * 1024 ))
fi
_mem_jobs=$(( _mem_bytes / 3221225472 ))        # 3 GB per job (measured peak 2.6 GB)
[ "$_mem_jobs" -lt 1 ] && _mem_jobs=1
_cpu_jobs=$(nproc)
[ "$_mem_jobs" -lt "$_cpu_jobs" ] && _default_jobs="$_mem_jobs" || _default_jobs="$_cpu_jobs"
: "${MAYHEM_JOBS:=$_default_jobs}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Offline-safe version stamp so autoreconf/git-version-gen never touches the network.
# Prefer the checkout's own tag (the image carries full .git); fall back to a fixed stamp so the
# build still works in a tagless/shallow tree and stays offline either way.
_ver="$(git -C "$SRC" describe --tags --abbrev=0 2>/dev/null || true)"
echo "${_ver:-0.14.8585}" > .tarball-version

# jsmn (single MIT header, a git submodule upstream) is vendored under mayhem/vendor/ so the build
# never touches the network even when the checkout has only the submodule gitlink.
mkdir -p jsmn
[ -f jsmn/jsmn.h ] || cp mayhem/vendor/jsmn.h jsmn/jsmn.h

autoreconf -fi -I m4

CONFIGURE_COMMON=(--disable-shared --disable-bindings --enable-release --disable-python --disable-gcov)

# Both builds are VPATH (out-of-tree) so the source dir stays pristine and re-running this script is
# idempotent (rm -rf + rebuild of each build dir; no in-tree configure state to collide with).

# 1) TEST build with the project's NORMAL flags, in its own VPATH tree so test.sh only RUNS it and
#    never false-fails on benign UB from the halting sanitizers.
rm -rf build-tests
mkdir -p build-tests
( cd build-tests && ../configure CC="$CC" CFLAGS="-O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" "${CONFIGURE_COMMON[@]}" )
make -j"$MAYHEM_JOBS" -C build-tests/src
make -j"$MAYHEM_JOBS" -C build-tests/test/unit-testing check-prep

# 2) FUZZ build: instrument the WHOLE library with SanitizerCoverage (-fsanitize=fuzzer-no-link) plus
#    ASan+UBSan. -fsanitize=fuzzer-no-link gives libFuzzer coverage feedback over the library code
#    path (not just the harness) — without it libFuzzer would fuzz blind over libredwg and the Mayhem
#    run would record ~0 edges even though everything builds and smokes fine.
#
#    The coverage flag is tied to $SANITIZER_FLAGS: the sancov callbacks (__sanitizer_cov_*) are
#    supplied by the ASan runtime (or libFuzzer), so with the documented off-switch
#    `--build-arg SANITIZER_FLAGS=` there is nothing left to resolve them and the *-standalone link
#    (which pulls in no fuzzing/sanitizer runtime) would fail. That mode exists to produce a natural
#    -crash reproducer, not to fuzz, so dropping instrumentation with it is the right trade.
COV_FLAGS="-fsanitize=fuzzer-no-link"
[ -n "${SANITIZER_FLAGS}" ] || COV_FLAGS=""
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $COV_FLAGS -O1"
rm -rf build-fuzz
mkdir -p build-fuzz
( cd build-fuzz && ../configure CC="$CC" CFLAGS="$FUZZ_CFLAGS" "${CONFIGURE_COMMON[@]}" )
make -j"$MAYHEM_JOBS" -C build-fuzz/src

LIB="$SRC/build-fuzz/src/.libs/libredwg.a"
[ -f "$LIB" ] || { echo "ERROR: $LIB not built" >&2; exit 1; }

# libFuzzer target (the Mayhem target: name "llvmfuzz").
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $COV_FLAGS -I"$SRC/include" -I"$SRC/src" -I"$SRC/build-fuzz/src" \
    -c "$SRC/examples/llvmfuzz.c" -o /tmp/llvmfuzz.o
# -lm explicitly: libredwg's geom.c needs sin/cos, which the ASan runtime happens to drag in. Without
# it the `--build-arg SANITIZER_FLAGS=` (no-sanitizer) build fails to link on undefined cos/sin.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE /tmp/llvmfuzz.o "$LIB" -lm -o /mayhem/llvmfuzz

# Standalone (non-fuzzer) reproducer over the same LLVMFuzzerTestOneInput code path.
# Deliberately NOT built with upstream's -DSTANDALONE main: that one picks the output converter and
# target DWG version with rand() seeded from gettimeofday(), so it would NOT reproduce a libFuzzer
# finding. Linking the canonical LLVM run-once driver ($STANDALONE_FUZZ_MAIN) against the same
# non-STANDALONE translation unit keeps the out/ver derivation identical to the fuzzer (hashed from
# the input), so a crashing input replays deterministically.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS /tmp/llvmfuzz.o /tmp/standalone_main.o "$LIB" -lm -o /mayhem/llvmfuzz-standalone

echo "build.sh: done — /mayhem/llvmfuzz, /mayhem/llvmfuzz-standalone, build-tests/ unit tests"
