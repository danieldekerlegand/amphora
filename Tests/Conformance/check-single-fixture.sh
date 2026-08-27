#!/usr/bin/env bash
# Tests/Conformance/check-single-fixture.sh — there is exactly ONE vectors.json, and both ports read it.
#
# The vectors exist for one reason: to stop the Swift and Kotlin state machines drifting apart.
# That only works while both ports read the SAME bytes. A per-platform copy — `android/src/test/
# resources/vectors.json`, or a "temporary" snapshot beside the Swift target — reintroduces
# precisely the drift the fixture was written to catch, and does it silently, because both suites
# stay green while describing different state machines.
#
# So the invariant is enforced rather than asserted in a comment. This script is cheap (it reads
# the git index, not the working tree) and runs as its own CI job; a second copy turns the build
# red on the commit that adds it, not on the release that ships the divergence.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root" || exit 1

canonical="Tests/Conformance/vectors.json"
# One vector id, used as a content fingerprint so a copy that was RENAMED on the way in is caught
# too. Filename matching alone would miss `conformance-vectors.json`.
sentinel="row-01-enqueue"
failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

if [ ! -f "$canonical" ]; then
  fail "$canonical is missing. The shared fixture is the whole mechanism; without it there is nothing for either port to conform to."
fi

# 1. No second file by that name. Match on the basename, not on a `*vectors.json` glob: that glob
#    also catches unrelated paths that merely END in those characters, such as the chief tasklist
#    `tasks/chief/completed/50-conformance-vectors.json`.
while IFS= read -r path; do
  [ -n "$path" ] || continue
  [ "$(basename "$path")" = "vectors.json" ] || continue
  [ "$path" = "$canonical" ] && continue
  fail "second copy of the fixture at $path — both ports must read $canonical, one file, no per-platform copy"
done < <(git ls-files)

# 2. No second file with that CONTENT, whatever it was named.
while IFS= read -r path; do
  [ -n "$path" ] || continue
  [ "$path" = "$canonical" ] && continue
  fail "renamed copy of the fixture at $path (it contains vector id '$sentinel') — one file, no per-platform copy"
done < <(git grep -l -F "$sentinel" -- '*.json' 2>/dev/null)

# 3. Both ports still name that exact path. A port that quietly repointed at its own fixture would
#    pass checks 1 and 2 by deleting nothing.
for port in ios/Tests/AmphoraTests/ConformanceTests.swift \
            android/src/test/kotlin/dev/amphora/ConformanceVectorsTest.kt; do
  if [ ! -f "$port" ]; then
    fail "$port is missing — a port that no longer runs the vectors cannot detect drift in the other"
  elif ! grep -qF "$canonical" "$port"; then
    fail "$port no longer references $canonical — the two ports must resolve the same file"
  fi
done

if [ "$failures" -ne 0 ]; then
  echo "check-single-fixture: ${failures} problem(s)" >&2
  exit 1
fi

echo "check-single-fixture: one fixture at $canonical, referenced by both ports"
