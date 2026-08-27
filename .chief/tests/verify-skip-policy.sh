#!/usr/bin/env bash
# .chief/tests/verify-skip-policy.sh — the counterfactual for the skip policy.
#
# Claim under test: a check that never ran can never read as a check that passed, and the two
# environments disagree about what to DO about that — locally a skip is tolerated and named,
# in CI it is a failure. Both halves are asserted here, against the real .chief/verify.sh.
#
# The counterfactual is produced by running verify.sh with an EMPTY PATH, so every toolchain
# it probes for — swift, java/gradle, npm — is genuinely absent. That is the "Android toolchain
# removed" condition of the story, plus the other two for free, and it costs no build time
# because nothing can run.
#
# Run it directly: .chief/tests/verify-skip-policy.sh   (CI runs it in the verify-policy job)
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bash_bin="$(command -v bash)"
empty_path="$(mktemp -d)"
trap 'rmdir "$empty_path" 2>/dev/null || true' EXIT

failures=0

fail() {
  echo "  NOT OK — $1"
  failures=$((failures + 1))
}

# Runs verify.sh from the repo root with no toolchain reachable. Echoes its output; returns
# its exit status. Every environment variable that selects a policy is set explicitly, so the
# test does not inherit the CI= of whatever runs it.
run_verify() {
  local strict="$1" ci="$2"
  ( cd "$repo_root" \
    && env -i \
        HOME="${HOME:-/tmp}" \
        PATH="$empty_path" \
        CI="$ci" \
        AMPHORA_VERIFY_STRICT="$strict" \
        "$bash_bin" .chief/verify.sh 2>&1 )
}

echo "== case 1: LOCAL, no toolchains — a skip must be reported as a skip, and must not fail the gate"
out="$(run_verify 0 "")"
status=$?
echo "$out" | sed 's/^/    | /'
[ "$status" -eq 0 ] || fail "expected exit 0 locally, got ${status}"
echo "$out" | grep -q "^SKIPPED Gradle build: no JDK on PATH" \
  || fail "expected 'SKIPPED Gradle build: no JDK on PATH'"
echo "$out" | grep -q "^PASS Gradle build" \
  && fail "a check that never ran reported PASS"
echo "$out" | grep -q "every check ran and passed" \
  && fail "a fully-skipped run claimed every check ran and passed"
echo "$out" | grep -q "This is NOT a full pass" \
  || fail "the summary did not disclaim the skipped checks"
# The summary must NAME every skipped check, not merely count them.
for label in "Swift build" "Swift tests" "Gradle build" "TypeScript typecheck"; do
  echo "$out" | grep -q "^  - ${label} — " \
    || fail "the skipped-check roster did not name '${label}'"
done

echo "== case 2: CI, no toolchains — the runner installs everything, so a skip is a bug and goes red"
out="$(run_verify "" true)"
status=$?
echo "$out" | sed 's/^/    | /'
[ "$status" -ne 0 ] || fail "expected a non-zero exit under CI=true, got 0"
echo "$out" | grep -q "^FAIL Gradle build: SKIPPED (no JDK on PATH)" \
  || fail "expected the skipped Gradle check to FAIL under CI=true"
echo "$out" | grep -q "^SKIPPED " \
  && fail "strict mode reported a bare SKIPPED instead of a failure"

echo "== case 3: AMPHORA_VERIFY_STRICT overrides the environment in both directions"
out="$(run_verify 1 "")"
status=$?
[ "$status" -ne 0 ] || fail "AMPHORA_VERIFY_STRICT=1 without CI should still be strict"
out="$(run_verify 0 true)"
status=$?
[ "$status" -eq 0 ] || fail "AMPHORA_VERIFY_STRICT=0 should relax even under CI=true"

echo
if [ "$failures" -ne 0 ]; then
  echo "verify-skip-policy: ${failures} assertion(s) failed"
  exit 1
fi
echo "verify-skip-policy: all assertions passed — SKIPPED is reported distinctly, named in the summary, and fatal in CI"
