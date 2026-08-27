#!/usr/bin/env bash
# .chief/verify.sh — run every check whose toolchain is present, and be loud about the rest.
#
# A SKIPPED CHECK IS NOT A PASSING CHECK. This script deliberately reports three outcomes,
# not two: PASS (it ran and succeeded), FAIL (it ran and did not), SKIPPED (it never ran, so
# the target is UNVERIFIED). Collapsing SKIPPED into PASS is how this repository accumulated
# green-looking merges for a Kotlin port that had never been handed to a compiler.
#
# TWO ENVIRONMENTS, TWO POLICIES — see docs/reference/continuous-integration.md.
#
#   LOCAL  A developer machine legitimately lacks toolchains (this project needs Swift on
#          macOS, a JDK plus the Android SDK, and Node). A missing one is a fact about the
#          machine, not a defect in the branch: report SKIPPED, name it in the summary, and
#          exit 0 so the developer is not blocked by a compiler they cannot install.
#
#   STRICT The CI workflow installs every toolchain before calling a gate. A check that
#   (CI)   skips there means the install step silently broke, and a gate that cannot run is
#          worth less than no gate at all, because it reports success. So in strict mode a
#          SKIP is a FAILURE and the run goes red.
#
# GitHub Actions sets CI=true, which selects strict automatically. AMPHORA_VERIFY_STRICT=1
# or =0 overrides in either direction; .chief/tests/verify-skip-policy.sh drives both paths
# with an emptied PATH and asserts the two verdicts differ.
set -uo pipefail

failures=0
passes=0
skips=0
skip_report=""

if [ -n "${AMPHORA_VERIFY_STRICT:-}" ]; then
  strict="${AMPHORA_VERIFY_STRICT}"
elif [ "${CI:-}" = "true" ]; then
  strict=1
else
  strict=0
fi

if [ "$strict" = "1" ]; then
  echo "verify: STRICT mode — every toolchain is expected to be installed here, so a SKIPPED check is a FAILURE."
else
  echo "verify: LOCAL mode — a missing toolchain reports SKIPPED (unverified). SKIPPED is not PASS."
fi

run_check() {
  local label="$1"
  shift
  echo "RUNNING ${label}"
  if "$@"; then
    echo "PASS ${label}"
    passes=$((passes + 1))
  else
    echo "FAIL ${label}"
    failures=$((failures + 1))
  fi
}

# Record a check that never ran. Always counted and always named in the summary; whether it
# also fails the run is the one thing the two environments disagree about.
skip_check() {
  local label="$1"
  local reason="$2"
  skips=$((skips + 1))
  skip_report="${skip_report}  - ${label} — ${reason}
"
  if [ "$strict" = "1" ]; then
    echo "FAIL ${label}: SKIPPED (${reason}) — in STRICT mode a check that cannot run is a failure"
    failures=$((failures + 1))
  else
    echo "SKIPPED ${label}: ${reason} — UNVERIFIED, not passed"
  fi
}

if command -v swift >/dev/null 2>&1 && [ -f ios/Package.swift ]; then
  run_check "Swift build" swift build --package-path ios
  run_check "Swift tests" swift run --package-path ios AmphoraPathTests
else
  skip_check "Swift build" "swift toolchain or ios/Package.swift unavailable"
  skip_check "Swift tests" "swift toolchain or ios/Package.swift unavailable"
fi

# A committed ./gradlew is not on its own enough to run one: the wrapper needs a JDK, and on a
# bare macOS box /usr/bin/java is a stub that exits non-zero. Probe for a real runtime, or this
# reports FAIL on a machine that simply has no toolchain.
if java -version >/dev/null 2>&1; then
  if [ -x ./gradlew ]; then
    run_check "Gradle build" ./gradlew build
  elif command -v gradle >/dev/null 2>&1; then
    run_check "Gradle build" gradle build
  else
    skip_check "Gradle build" "no Gradle wrapper or gradle on PATH"
  fi
else
  skip_check "Gradle build" "no JDK on PATH"
fi

if command -v npm >/dev/null 2>&1 && [ -f packages/react-native/package.json ]; then
  if [ ! -d packages/react-native/node_modules ]; then
    run_check "TypeScript dependency install" npm --prefix packages/react-native ci
  fi
  run_check "TypeScript typecheck" npm --prefix packages/react-native run typecheck
else
  skip_check "TypeScript typecheck" "npm or packages/react-native/package.json unavailable"
fi

echo
echo "verify: ${passes} passed, ${skips} skipped, ${failures} failed"

if [ "$skips" -ne 0 ]; then
  echo "verify: SKIPPED checks — these did NOT run and are UNVERIFIED:"
  printf '%s' "$skip_report"
fi

if [ "$failures" -ne 0 ]; then
  echo "verify: ${failures} check(s) failed"
  exit 1
fi

if [ "$skips" -ne 0 ]; then
  echo "verify: nothing failed, but ${skips} check(s) never ran. This is NOT a full pass."
  exit 0
fi

echo "verify: every check ran and passed"
