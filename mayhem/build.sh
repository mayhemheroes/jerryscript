#!/usr/bin/env bash
#
# jerryscript/mayhem/build.sh — build jerryscript's OSS-Fuzz harness (jerry-main/main-libfuzzer.c)
# as a sanitized libFuzzer target (+ a standalone run-once reproducer).
#
# The fuzzed surface is the WHOLE JS engine: the harness feeds raw input as a UTF-8 JS source string
# to jerry_validate_string -> jerry_parse -> jerry_run -> jerry_run_jobs (and frees results). So both
# the parser and the bytecode VM / builtins are exercised on attacker-controlled JavaScript.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). We compile the jerry libraries THEMSELVES with $SANITIZER_FLAGS so the
# engine (not just the harness) is instrumented.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# The base image's clang is newer/stricter than jerryscript's CI clang and turns two benign
# enum-conversion patterns in jerry-core into errors under its global -Werror:
#   -Wenum-enum-conversion / -Wenum-float-conversion  (e.g. (lit_magic_string_id_t)(FIRST + symbol),
#   ECMA_PROPERTY_FLAG_WRITABLE | JERRY_PROP_SHOULD_THROW). These are intentional cross-enum bit/arith
#   ops in the engine, not bugs. Demote ONLY these to warnings via EXTERNAL flags (applied AFTER
#   jerry's -Werror, so they win). ASan+UBSan and every other -Werror stay halting.
CC_WARN_RELAX="-Wno-error=enum-enum-conversion -Wno-error=enum-float-conversion"

# js-scanner-util.c:2345 does `ptr + 0` on a possibly-NULL scratch pointer — UBSan flags
# "applying zero offset to null pointer" on essentially EVERY parsed input (empty included), which
# would make the fuzzer report a finding on its very first run and never explore. This is a benign,
# well-defined-in-practice no-op pointer adjustment in the lexer, not a memory bug. Suppress ONLY this
# one UBSan check (pointer-overflow); ASan and all other UBSan checks stay halting.
UBSAN_RELAX="-fno-sanitize=pointer-overflow"

HARNESS="$SRC/jerry-main/main-libfuzzer.c"
STANDALONE_DRIVER="$SRC/mayhem/harnesses/jerry_libfuzzer_standalone.c"
INC="-I$SRC/jerry-core/include"

# ── 1) Build jerry's static libraries WITH sanitizers via its own CMake (libfuzzer OFF here: we want
#       instrumented engine libs we can relink against, NOT jerry's bundled fuzzer executable). LTO is
#       turned OFF (it fights libFuzzer/sanitizer linking) and stripping OFF (keep symbols for ASan).
#       CRITICAL: also pass -fsanitize=fuzzer-no-link so the ENGINE itself carries libFuzzer coverage
#       (SanitizerCoverage) counters — otherwise only the harness file is instrumented (4 PCs) and the
#       fuzzer cannot explore the engine. (no-link = instrument but don't pull in the fuzzer main.) ──
COV="-fsanitize=fuzzer-no-link"
BUILD="$SRC/mayhem-build"
rm -rf "$BUILD"
cmake -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DENABLE_LTO=OFF -DENABLE_STRIP=OFF \
  -DJERRY_CMDLINE=OFF -DJERRY_LIBFUZZER=OFF \
  -DEXTERNAL_COMPILE_FLAGS="$SANITIZER_FLAGS $COV $UBSAN_RELAX $CC_WARN_RELAX $DEBUG_FLAGS" \
  -DEXTERNAL_LINKER_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
cmake --build "$BUILD" --target jerry-core jerry-port -j"$MAYHEM_JOBS"

LIBS=("$BUILD"/lib/libjerry-core.a "$BUILD"/lib/libjerry-port.a)
ls -la "${LIBS[@]}"

# ── 2) Link the harness twice against the instrumented libs ────────────────────────────────────────
#   libFuzzer target -> /mayhem/jerry-libfuzzer
$CC $SANITIZER_FLAGS $UBSAN_RELAX $DEBUG_FLAGS $INC \
    "$HARNESS" $LIB_FUZZING_ENGINE "${LIBS[@]}" -lm \
    -o /mayhem/jerry-libfuzzer

#   standalone reproducer (no libFuzzer runtime; reads one input file) -> /mayhem/jerry-libfuzzer-standalone
$CC $SANITIZER_FLAGS $UBSAN_RELAX $DEBUG_FLAGS $INC \
    "$HARNESS" "$STANDALONE_DRIVER" "${LIBS[@]}" -lm \
    -o /mayhem/jerry-libfuzzer-standalone

echo "built jerry-libfuzzer (+ standalone)"

echo "build.sh complete:"
ls -la /mayhem/jerry-libfuzzer /mayhem/jerry-libfuzzer-standalone 2>&1 || true
