#!/usr/bin/env bash
#
# jerryscript/mayhem/test.sh — build jerryscript's OWN unit-core test suite with NORMAL flags
# (independent of the sanitized fuzz build) and RUN it, emitting a CTRF summary. exit 0 iff no test
# failed.
#
# PATCH-grade oracle: tests/unit-core/ is jerryscript's C unit-test suite — each unit-* binary
# exercises the public jerry_* C API (parse/run, value types, arithmetic, promises, typed arrays,
# regexp, snapshots, ...) with hard assert()s on observed engine behaviour. A no-op / "return 0"
# patch to the engine cannot keep these green. This script BUILDS the suite in a clean tree with
# normal flags (so it is an honest behavioural oracle, not sanitizer noise) and then runs every
# unit-* binary directly.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

TESTBUILD="$SRC/mayhem-tests"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

# ── Build the unit-core suite with normal flags (env -u so the sanitizer/build contract does not
#    leak in). UNITTESTS=ON builds the tests/unit-core/unit-* binaries into <build>/tests/. ─────────
echo "=== building unit-core test suite in $TESTBUILD ==="
if ! command -v cmake >/dev/null 2>&1; then
  echo "cmake not available — cannot build the unit tests" >&2
  emit_ctrf "jerry-unit-core" 0 1 0; exit 2
fi

rm -rf "$TESTBUILD"
CC_WARN_RELAX="-Wno-error=enum-enum-conversion -Wno-error=enum-float-conversion"
if ! env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
      cmake -S "$SRC" -B "$TESTBUILD" \
        -DCMAKE_BUILD_TYPE=Debug \
        -DUNITTESTS=ON -DJERRY_CMDLINE=ON -DENABLE_LTO=OFF -DENABLE_STRIP=OFF \
        -DJERRY_ERROR_MESSAGES=ON -DJERRY_SNAPSHOT_SAVE=ON -DJERRY_SNAPSHOT_EXEC=ON \
        -DJERRY_VM_HALT=ON -DJERRY_VM_THROW=ON -DJERRY_LINE_INFO=ON \
        -DJERRY_MEM_STATS=ON -DJERRY_PROMISE_CALLBACK=ON \
        -DEXTERNAL_COMPILE_FLAGS="$CC_WARN_RELAX"; then
  echo "cmake configure failed" >&2
  emit_ctrf "jerry-unit-core" 0 1 0; exit 2
fi
if ! env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
      cmake --build "$TESTBUILD" -j"$MAYHEM_JOBS"; then
  echo "unit-core build failed" >&2
  emit_ctrf "jerry-unit-core" 0 1 0; exit 2
fi

# ── Run every unit-* test binary directly and count pass/fail ──────────────────────────────────────
mapfile -t TESTS < <(find "$TESTBUILD/tests" -maxdepth 1 -type f -name 'unit-*' -perm -u+x 2>/dev/null | sort)
TOTAL=${#TESTS[@]}
if [ "$TOTAL" -eq 0 ]; then
  echo "no unit-* test binaries found under $TESTBUILD/tests" >&2
  emit_ctrf "jerry-unit-core" 0 1 0; exit 2
fi

PASSED=0; FAILED=0
for t in "${TESTS[@]}"; do
  name="$(basename "$t")"
  if out="$("$t" 2>&1)"; then
    PASSED=$((PASSED+1))
    echo "PASS  $name"
  else
    rc=$?
    FAILED=$((FAILED+1))
    echo "FAIL ($rc)  $name"
    echo "------------------------------------------------"
    printf '%s\n' "$out" | tail -30
    echo "------------------------------------------------"
  fi
done

# ── Behavioral oracle: run a few simple JS snippets through the jerry CLI to verify the engine works ──
# This produces observable output and cannot be faked by a neutered exit(0) stub.
echo "=== running behavioral smoke tests ==="
BEHAVIOR_PASS=0; BEHAVIOR_FAIL=0
declare -a JSTEST_CASES=(
  "1+1"
  "function f(x){return x*2} f(5)"
  "[1,2,3].length"
  "({a:1}).a"
)
JERRY="$TESTBUILD/bin/jerry"
if [ ! -x "$JERRY" ]; then
  echo "jerry CLI not found at $JERRY" >&2
  BEHAVIOR_FAIL=4
else
  for jstest in "${JSTEST_CASES[@]}"; do
    result="$("$JERRY" <<< "$jstest" 2>&1)"
    if [ -n "$result" ] && [[ "$result" != *"Error"* ]] && [[ "$result" != *"error"* ]]; then
      BEHAVIOR_PASS=$((BEHAVIOR_PASS+1))
      echo "PASS  JS: $jstest → $result"
    else
      BEHAVIOR_FAIL=$((BEHAVIOR_FAIL+1))
      FAILED=$((FAILED+1))
      echo "FAIL  JS: $jstest"
      [ -n "$result" ] && printf '%s\n' "$result"
    fi
  done
fi
TOTAL=$((TOTAL + ${#JSTEST_CASES[@]}))

echo "=== unit-core: $PASSED passed, $FAILED failed (of $TOTAL) ==="
emit_ctrf "jerry-unit-core" "$((PASSED + BEHAVIOR_PASS))" "$((FAILED + BEHAVIOR_FAIL))" 0
