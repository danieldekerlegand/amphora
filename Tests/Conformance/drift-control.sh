#!/usr/bin/env bash
# Tests/Conformance/drift-control.sh — the counterfactual for the conformance vectors.
#
# CLAIM UNDER TEST: the vectors detect drift between the Swift and Kotlin ports.
#
# A drift detector nobody has watched detect drift is indistinguishable from one that cannot, and
# this repository has already shipped one of those: forty vectors that ran on Swift only, so any
# Kotlin divergence would have passed unremarked while the suite reported green. Both suites being
# green today proves the two ports AGREE. It does not prove the suite would NOTICE if they did not.
#
# So this script introduces a deliberate divergence into ONE port at a time, runs that port's
# vectors, and requires them to go RED naming the vector that caught it. Four controls, two per
# port:
#
#   1. state-machine drift — `SourceMissing` stops meaning FAILED(SOURCE_GONE) and starts meaning
#      BLOCKED(STORAGE_LOW) in one port. `row-04-source-missing` must catch it.
#   2. I6 drift — the transport materialises a chunk temp file during an attempt. The
#      `transportInvariants.i6NoChunkTempFiles` rows must catch it. This is the one worth the most:
#      staging "just the remainder" is the plausible, well-meaning change that takes peak extra
#      storage from about zero to the size of the file, and no transition vector would notice.
#
# Each control edits a source file in the working tree, runs the suite, and restores the file from
# a byte-for-byte backup — on every exit path, including interrupt. It leaves no commit and no
# stash behind. If a mutation's anchor text is ever gone, the run FAILS rather than passing
# vacuously: a control that silently mutates nothing reports success, which is the failure mode
# this whole file exists to rule out.
#
#   Tests/Conformance/drift-control.sh                # both ports, whatever toolchains are here
#   Tests/Conformance/drift-control.sh --port kotlin  # just one
#
# TWO ENVIRONMENTS, TWO POLICIES — the same split as .chief/verify.sh. Locally a missing toolchain
# reports SKIPPED and exits 0, because a developer machine legitimately lacks Swift or a JDK. In CI
# (`CI=true`, or `AMPHORA_VERIFY_STRICT=1`) the runner installs everything, so a skip means the
# install broke and the run goes red.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root" || exit 1
mutator="$root/Tests/Conformance/apply-mutation.py"

port="both"
case "${1:-}" in
  "") ;;
  --port) port="${2:-both}" ;;
  *) echo "usage: $0 [--port swift|kotlin|both]" >&2; exit 2 ;;
esac

if [ -n "${AMPHORA_VERIFY_STRICT:-}" ]; then
  strict="${AMPHORA_VERIFY_STRICT}"
elif [ "${CI:-}" = "true" ]; then
  strict=1
else
  strict=0
fi

failures=0
controls=0
skips=0

fail() { echo "NOT OK — $*" >&2; failures=$((failures + 1)); }

skip() {
  skips=$((skips + 1))
  if [ "$strict" = "1" ]; then
    echo "FAIL ${1}: SKIPPED (${2}) — in STRICT mode a control that cannot run is a failure" >&2
    failures=$((failures + 1))
  else
    echo "SKIPPED ${1}: ${2} — UNVERIFIED, not passed"
  fi
}

# --- restore-on-exit -----------------------------------------------------------------------------
# Every mutated file is copied aside before it is touched and copied back on exit, whatever the
# exit is. The files below are the only ones these controls may touch; each is also snapshotted at
# startup so the end-of-run check can prove the script put every one of them back byte for byte.
targets=(
  ios/Sources/Amphora/Core/UploadStateMachine.swift
  ios/Sources/Amphora/Transport/NativeResumableTransport.swift
  android/src/main/kotlin/dev/amphora/core/UploadStateMachine.kt
  android/src/main/kotlin/dev/amphora/transport/TusTransport.kt
)
pristine_dir="$(mktemp -d)"
pristine_index=0
for target in "${targets[@]}"; do
  cp "$root/$target" "${pristine_dir}/${pristine_index}.orig"
  pristine_index=$((pristine_index + 1))
done

backup_dir="$(mktemp -d)"
mutation_count=0
stack=()          # "<backup-index>:<path>", most recent last

restore_all() {
  local entry
  for entry in ${stack[@]+"${stack[@]}"}; do
    cp "${backup_dir}/${entry%%:*}.bak" "$root/${entry#*:}"
  done
  stack=()
  rm -rf "$backup_dir"
}
trap 'restore_all' EXIT INT TERM

mutate() {   # mutate <file> <old-text> <new-text>
  local file="$1" old="$2" new="$3"
  cp "$root/$file" "${backup_dir}/${mutation_count}.bak"
  stack+=("${mutation_count}:${file}")
  mutation_count=$((mutation_count + 1))
  # A mutation that changed nothing would make the control below it vacuous, so a missing anchor
  # is fatal rather than a warning.
  if ! python3 "$mutator" "$root/$file" "$old" "$new"; then
    echo "drift-control: could not apply the mutation to ${file}" >&2
    exit 1
  fi
}

restore_last() {   # undo the most recent mutation, so controls do not stack
  local count="${#stack[@]}"
  [ "$count" -gt 0 ] || return 0
  local entry="${stack[$((count - 1))]}"
  cp "${backup_dir}/${entry%%:*}.bak" "$root/${entry#*:}"
  if [ "$count" -eq 1 ]; then
    stack=()
  else
    stack=("${stack[@]:0:$((count - 1))}")
  fi
}

# --- the controls --------------------------------------------------------------------------------
# run_control <label> <expected-substring> <command...>
#   The command MUST exit non-zero AND print the expected substring. Non-zero alone is not enough:
#   a source file that no longer compiles also exits non-zero, and would let a control "pass"
#   without a single vector having run.
run_control() {
  local label="$1" expected="$2"
  shift 2
  controls=$((controls + 1))
  echo "== ${label}"
  local output status
  output="$("$@" 2>&1)"
  status=$?
  printf '%s\n' "$output" | sed 's/^/    | /'
  if [ "$status" -eq 0 ]; then
    fail "${label}: the suite PASSED with the divergence in place. The vectors do not catch this."
    return
  fi
  if ! printf '%s' "$output" | grep -qF "$expected"; then
    fail "${label}: went red, but not for the expected reason — no '${expected}' in the output. A control that fires on the wrong failure proves nothing."
    return
  fi
  echo "  OK — red, and it named '${expected}'"
}

swift_vectors() { swift run --package-path "$root/ios" AmphoraPathTests; }

kotlin_vectors() {
  # --no-daemon: a warm daemon holding stale classes would make a control unfalsifiable. The XML
  # report carries the assertion message even when console formatting elides it, so both are
  # searched.
  ( cd "$root" && ./gradlew --no-daemon :android:testDebugUnitTest --tests 'dev.amphora.ConformanceVectorsTest' )
  local status=$?
  cat "$root"/android/build/test-results/testDebugUnitTest/*.xml 2>/dev/null
  return $status
}

if [ "$port" = "swift" ] || [ "$port" = "both" ]; then
  if command -v swift >/dev/null 2>&1; then
    mutate ios/Sources/Amphora/Core/UploadStateMachine.swift \
      'return fail(job, .sourceGone, "source no longer readable", now)' \
      'return block(job, .storageLow, now)'
    run_control "swift / state-machine drift: SourceMissing becomes BLOCKED" "row-04-source-missing" swift_vectors
    restore_last

    mutate ios/Sources/Amphora/Transport/NativeResumableTransport.swift \
      '        return TransferHandle(taskIdentifier: taskId, stagedRemainderPath: nil)' \
      '        try? Data(count: 16).write(to: fileURL.deletingLastPathComponent().appendingPathComponent(job.id + ".chunk"))
        return TransferHandle(taskIdentifier: taskId, stagedRemainderPath: nil)'
    run_control "swift / I6 drift: the transport writes a chunk temp file" "I6 violated" swift_vectors
    restore_last
  else
    skip "swift drift controls" "no swift toolchain on PATH"
  fi
fi

if [ "$port" = "kotlin" ] || [ "$port" = "both" ]; then
  if java -version >/dev/null 2>&1 && [ -x ./gradlew ]; then
    mutate android/src/main/kotlin/dev/amphora/core/UploadStateMachine.kt \
      'is UploadEvent.SourceMissing -> fail(job, ErrorClass.SOURCE_GONE, "source no longer readable", now)' \
      'is UploadEvent.SourceMissing -> block(job, BlockReason.STORAGE_LOW, now)'
    run_control "kotlin / state-machine drift: SourceMissing becomes BLOCKED" "row-04-source-missing" kotlin_vectors
    restore_last

    mutate android/src/main/kotlin/dev/amphora/transport/TusTransport.kt \
      '        source.channel.position(offset)' \
      '        java.io.File(System.getProperty("java.io.tmpdir"), "amphora-drift-chunk.tmp").writeBytes(ByteArray(16))
        source.channel.position(offset)'
    run_control "kotlin / I6 drift: the transport writes a chunk temp file" "I6 violated" kotlin_vectors
    restore_last
  else
    skip "kotlin drift controls" "no JDK on PATH, or no Gradle wrapper"
  fi
fi

# --- the tree must be exactly as it was found ----------------------------------------------------
# Compared against the pristine copies taken at startup, NOT against git: this script is expected
# to run on a working tree that already carries uncommitted work, and "clean according to git" is
# a different claim from "untouched by this script".
restore_all
trap - EXIT INT TERM
index=0
for target in "${targets[@]}"; do
  if ! cmp -s "${pristine_dir}/${index}.orig" "$root/$target"; then
    fail "${target} was left modified by this script. Restore it from git before committing."
  fi
  index=$((index + 1))
done
rm -rf "$pristine_dir"

echo
echo "drift-control: ${controls} control(s) ran, ${skips} skipped, ${failures} failure(s)"
if [ "$failures" -ne 0 ]; then
  exit 1
fi
if [ "$controls" -eq 0 ]; then
  echo "drift-control: nothing ran. That is NOT a pass — see the SKIPPED lines above."
  exit 0
fi
echo "drift-control: every divergence introduced was caught by the vectors that were supposed to catch it"
