#!/usr/bin/env bash
#
# mayhem/test.sh — RUN LibreDWG's own unit-test suite (built by mayhem/build.sh with normal flags).
# The suite is automake-driven `make check` in test/unit-testing: decode/encode/dxf/dynapi/bits/hash/
# common tests plus the per-object roundtrip tests — assertion-based (a no-op/exit(0) patch fails them).
# Emits a CTRF summary and exits non-zero iff any test failed.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

TESTDIR="$SRC/build-tests/test/unit-testing"
[ -d "$TESTDIR" ] || { echo "ERROR: $TESTDIR missing — mayhem/build.sh did not build the tests" >&2; exit 1; }

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Run the automake test harness. It writes per-test .log + a test-suite.log and prints a summary
# ("# TOTAL:/# PASS:/# FAIL:/# SKIP:/# XFAIL:/# ERROR:").
LOG="$(mktemp)"
make -C "$TESTDIR" check -j"$MAYHEM_JOBS" >"$LOG" 2>&1 || true
cat "$LOG"

# Parse the automake summary. This tree uses the SERIAL test harness (`serial-tests` in
# configure.ac): "All N tests passed" / "M of N tests failed" (+ "(K tests were not run)").
# Fall back to the parallel-harness "# TOTAL:/# PASS:/..." block if present.
grab() { grep -aE "^# $1:" "$LOG" | tail -1 | grep -aoE '[0-9]+' | tail -1; }
total="$(grab TOTAL)"; pass="$(grab PASS)"; fail="$(grab FAIL)"; skip="$(grab SKIP)"
xfail="$(grab XFAIL)"; xpass="$(grab XPASS)"; err="$(grab ERROR)"
: "${total:=0}"; : "${pass:=0}"; : "${fail:=0}"; : "${skip:=0}"; : "${xfail:=0}"; : "${xpass:=0}"; : "${err:=0}"
if [ "$total" -eq 0 ]; then
  allpass="$(grep -aoE 'All [0-9]+ tests (passed|behaved as expected)' "$LOG" | tail -1 | grep -aoE '[0-9]+')"
  somefail="$(grep -aoE '[0-9]+ of [0-9]+ tests (failed|did not behave as expected)' "$LOG" | tail -1)"
  notrun="$(grep -aoE '\([0-9]+ tests? were not run\)' "$LOG" | tail -1 | grep -aoE '[0-9]+')"
  skip="${notrun:-0}"
  if [ -n "$somefail" ]; then
    fail="$(printf '%s' "$somefail" | grep -aoE '^[0-9]+')"
    total="$(printf '%s' "$somefail" | grep -aoE '[0-9]+' | sed -n 2p)"
    pass=$(( total - fail ))
  elif [ -n "$allpass" ]; then
    pass="$allpass"; total="$allpass"; fail=0
  fi
fi

if [ "$total" -eq 0 ]; then
  echo "ERROR: no automake test summary found — the suite did not run" >&2
  emit_ctrf "automake-check" 0 1 0   # non-zero
  exit 1
fi

# XPASS (unexpected pass) and ERROR count as failures for the oracle; XFAIL is expected → skipped.
failed=$(( fail + xpass + err ))
skipped=$(( skip + xfail ))

# Behavioral known-answer assertion (§6.3): the automake serial harness is exit-code driven, so also
# require a test binary to actually PRINT its TAP results — a neutered exit(0) binary produces none.
if "$TESTDIR/bits_test" 2>/dev/null | grep -q '^ok .*bit_advance_position'; then
  pass=$(( pass + 1 ))
else
  echo "ERROR: bits_test emitted no TAP output — program neutered or broken" >&2
  failed=$(( failed + 1 ))
fi

emit_ctrf "automake-check" "$pass" "$failed" "$skipped"
