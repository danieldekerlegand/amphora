#!/usr/bin/env bash
# .chief/verify.sh — verify every target whose toolchain is available.
set -uo pipefail

failures=0

run_check() {
  local label="$1"
  shift
  echo "RUNNING ${label}"
  if "$@"; then
    echo "PASS ${label}"
  else
    echo "FAIL ${label}"
    failures=$((failures + 1))
  fi
}

if command -v swift >/dev/null 2>&1 && [ -f ios/Package.swift ]; then
  run_check "Swift build" swift build --package-path ios
  run_check "Swift tests" swift run --package-path ios AmphoraPathTests
else
  echo "SKIPPED Swift: swift toolchain or ios/Package.swift unavailable; Swift build and tests unverified"
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
    echo "SKIPPED Gradle: Gradle wrapper/command unavailable; Android build unverified"
  fi
else
  echo "SKIPPED Gradle: no JDK on PATH; Android build unverified"
fi

if command -v npm >/dev/null 2>&1 && [ -f packages/react-native/package.json ]; then
  if [ ! -d packages/react-native/node_modules ]; then
    run_check "TypeScript dependency install" npm --prefix packages/react-native ci
  fi
  run_check "TypeScript typecheck" npm --prefix packages/react-native run typecheck
else
  echo "SKIPPED TypeScript: npm or packages/react-native/package.json unavailable; TypeScript typecheck unverified"
fi

if [ "$failures" -ne 0 ]; then
  echo "verify: ${failures} reachable target check(s) failed"
  exit 1
fi

echo "verify: all reachable target checks passed; skipped targets were reported above"
