#!/usr/bin/env bash
#
# mayhem/build.sh — build LibreDWG's llvmfuzz harness (libFuzzer + standalone) AND its unit-test
# suite. Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem == $SRC.
#
# Layout produced:
#   /mayhem/llvmfuzz              libFuzzer target (SanitizerCoverage + ASan/UBSan)   <- the Mayhem target
#   /mayhem/llvmfuzz-standalone   run-once file-input reproducer (same code path)
#   $SRC/.build-tests/...         the project's unit tests, built with NORMAL flags for mayhem/test.sh
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# Parallelism is bounded by MEMORY, not by core count: LibreDWG's generated TUs (src/encode2.c,
# src/out_json.c, src/out_dxfb.c) are enormous, and a plain `-j$(nproc)` on a many-core builder
# launches that many at once and is OOM-killed inside a small cgroup (verify-repo.sh runs every
# container at VERIFY_DOCKER_MEM, rlenv's graded build at its own limit).  The fuzz build below is
# -O0 with the full sanitizer set, whose measured peak is ~3.7 GB per clang (out_json.c); 4 GB per job
# leaves headroom for make/libtool.  MAYHEM_JOBS from the environment still wins.
# Read the CGROUP budget, not /proc/meminfo -- inside a container the latter reports the host's
# RAM.  cgroup v2 first, then v1; "max" or a missing file means unlimited, in which case fall back
# to the host total.
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
_mem_jobs=$(( _mem_bytes / 4294967296 ))        # 4 GB per job (measured peak ~3.7 GB)
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

# Build time is what rlenv's graded rebuild is limited by (450 s, cold, a few jobs), so both builds are
# -O0: LibreDWG's generated translation units (src/out_json.c, out_dxfb.c, encode2.c, decode2.c, ...)
# take 100-300 s EACH under clang -O1 with ASan+UBSan+SanitizerCoverage (measured 276 s for out_json.c
# alone, ~1400 CPU-s for the library) but ~20-60 s at -O0.
# Build dirs are .build-tests/.build-fuzz: upstream's .gitignore already covers `/.build-*/`, so the
# graded `git clean -ffdX` removes every configure/object file instead of leaving a stale tree behind.

# 1) TEST build with the project's NORMAL flags (no sanitizers), in its own VPATH tree so test.sh only
#    RUNS it and never false-fails on benign UB from the halting sanitizers.  -U_FORTIFY_SOURCE: the
#    project defines _FORTIFY_SOURCE=3, which glibc turns into a #warning (an error under the
#    project's -Werror) without optimization.
rm -rf .build-tests
mkdir -p .build-tests
( cd .build-tests && ../configure CC="$CC" CFLAGS="-O0 -U_FORTIFY_SOURCE $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" "${CONFIGURE_COMMON[@]}" )
make -j"$MAYHEM_JOBS" -C .build-tests/src
make -j"$MAYHEM_JOBS" -C .build-tests/test/unit-testing check-prep

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
# -O0 with the FULL $SANITIZER_FLAGS on the library objects (ASan + every UBSan check, halting; `null` and
# `alignment` included: ASan does not see misaligned loads/stores).  Measured cold, 2 cpus, 12 GB: 308-324 s
# for the whole build (193 s with those two checks off, 291 s with only `null` off, since `alignment` also
# instruments every load/store), so the 450 s limit holds with the checks on.
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $COV_FLAGS -O0"
rm -rf .build-fuzz
mkdir -p .build-fuzz
( cd .build-fuzz && ../configure CC="$CC" CFLAGS="$FUZZ_CFLAGS" "${CONFIGURE_COMMON[@]}" )
make -j"$MAYHEM_JOBS" -C .build-fuzz/src

LIB="$SRC/.build-fuzz/src/.libs/libredwg.a"
[ -f "$LIB" ] || { echo "ERROR: $LIB not built" >&2; exit 1; }

# LeakSanitizer off at build time (SPEC 6.1 item 15); ASan and UBSan stay on.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o /tmp/lsan_off.o

# libFuzzer target (the Mayhem target: name "llvmfuzz").
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $COV_FLAGS -I"$SRC/include" -I"$SRC/src" -I"$SRC/.build-fuzz/src" \
    -c "$SRC/examples/llvmfuzz.c" -o /tmp/llvmfuzz.o
# -lm explicitly: libredwg's geom.c needs sin/cos, which the ASan runtime happens to drag in. Without
# it the `--build-arg SANITIZER_FLAGS=` (no-sanitizer) build fails to link on undefined cos/sin.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE /tmp/llvmfuzz.o /tmp/lsan_off.o "$LIB" -lm -o /mayhem/llvmfuzz

# Standalone (non-fuzzer) reproducer over the same LLVMFuzzerTestOneInput code path.
# Deliberately NOT built with upstream's -DSTANDALONE main: that one picks the output converter and
# target DWG version with rand() seeded from gettimeofday(), so it would NOT reproduce a libFuzzer
# finding. Linking the canonical LLVM run-once driver ($STANDALONE_FUZZ_MAIN) against the same
# non-STANDALONE translation unit keeps the out/ver derivation identical to the fuzzer (hashed from
# the input), so a crashing input replays deterministically.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS /tmp/llvmfuzz.o /tmp/standalone_main.o /tmp/lsan_off.o "$LIB" -lm -o /mayhem/llvmfuzz-standalone

echo "build.sh: done — /mayhem/llvmfuzz, /mayhem/llvmfuzz-standalone, .build-tests/ unit tests"
