# Continuous integration

> **Status:** Live · **Updated:** 2026-08-26 · **Owner:** Amphora

Until 2026-08-26 this repository had **no git remote**. `.github/workflows/ci.yml` had existed
for weeks and had never executed on any machine, which made every Android claim in this
repository *unfalsifiable* rather than false: the Kotlin port had never been compiled by
anything, and the Kotlin half of the conformance vectors had never been run. This document
records the decisions that ended that, so they are not quietly undone.

## Remote

`origin` → <https://github.com/danieldekerlegand/amphora>

## Visibility: public, deliberately

GitHub Actions minutes are **free for public repositories and billed for private ones**. This
account's private-repository Actions are currently blocked outright:

> The job was not started because recent account payments have failed or your spending limit
> needs to be increased.

A private `amphora` would therefore have produced a workflow that *cannot start* — the same
un-runnable gate this work exists to remove, with a green-looking configuration in front of it.
The repository is public so that CI can actually run.

What was checked before publishing: the tree carries no credentials. The only secret-shaped
strings are the placeholder MinIO/tusd credentials in `integration/tusd/docker-compose.yml`,
which exist solely to bring up a throwaway local container.

**If this repository is ever made private, CI stops being a gate** until billing is confirmed
working — a private run that never starts reports no failure, and "no failure" is not a pass.
Say so out loud at that point rather than leaving the workflow file to imply coverage.

## Trigger: `push` on `main` and `chief/**`

Work is not delivered here by pull request. Chief merges a finished tasklist branch into `main`
locally with `--no-ff` and pushes `main`; no PR is ever opened. A `pull_request`-only trigger
would consequently never fire — the failure mode observed in the sibling repository `vita`,
whose workflow went its whole life without a single run.

So the trigger is:

| Event | Why |
|---|---|
| `push` to `main` | The path every merged tasklist actually takes. |
| `push` to `chief/**` | Builds a tasklist branch *before* it is merged, not only after. |
| `pull_request` | Retained for humans who do open one. Not the primary path. |
| `workflow_dispatch` | Forces a run without inventing a commit. |

The reasoning is repeated as a comment at the top of `.github/workflows/ci.yml`, because that is
where a future reader will meet it and be tempted to "tidy" it back.

## Reading a run

```sh
gh run list --limit 5
gh run view <run-id>
```

A run's **conclusion** is the claim. "CI is wired" is not evidence; a run id and its conclusion
are. Related: [Environmental claim evidence](environment-evidence.md).

## The conformance vectors run on both ports

`Tests/Conformance/vectors.json` (40 vectors, `schemaVersion` 1) exists for exactly one reason: to
stop the Swift and Kotlin state machines drifting apart. A vector suite that runs on one platform
cannot do that — it provides assurance without verification, which is worse than an acknowledged
gap. Both ports therefore run in CI, against that one file:

| Job | Step | What runs the vectors |
|---|---|---|
| `ios` | `swift run --package-path ios AmphoraPathTests` | `UploadPathTests.conformanceVectors()` |
| `android` | `./gradlew --no-daemon :android:testDebugUnitTest` | `ConformanceVectorsTest.sharedVectorsMatchAndroidPort` |
| `conformance-fixture` | `Tests/Conformance/check-single-fixture.sh` | Nothing — it gates the *one file* invariant |

Neither port reaches the fixture by a working-directory-relative path. Swift walks up from
`#filePath`; Kotlin uses the `amphora.repoRoot` system property `android/build.gradle.kts` injects,
falling back to walking up from `user.dir`. A fixture the runner cannot find used to crash with
`NSCocoaErrorDomain 260`, which reads as a broken machine rather than as a red test; both ports now
fail with the list of paths they searched.

### Ran-zero-vectors is a failure

`BUILD SUCCESSFUL` on a task that executed nothing looks exactly like one that executed forty, so
neither port is allowed to discover its own scope. Each asserts, independently of the fixture:

- `schemaVersion == 1`;
- exactly **40** vectors, checked *before* the first reduction, so a truncated file fails as
  "expected 40 vectors, got 18" rather than as whichever unrelated assertion those 18 trip over;
- exactly **1** non-reducing vector (`row-01-enqueue` — `Enqueue` creates a job rather than
  reducing one) and therefore exactly **39** rows actually put through `reduce`. Without this last
  pair a fixture whose rows had all degenerated to `Enqueue` would skip all forty, exercise
  nothing, and still report green.

Those three numbers live in the tests, not in the fixture, so a fixture rewritten by a generator
cannot rewrite its own expectations alongside it. Adding a vector means touching both ports; that
friction is the point.

### One file, no per-platform copy

The whole mechanism depends on both ports reading the same bytes. A second copy — a snapshot under
`android/src/test/resources/`, a renamed `conformance-snapshot.json` beside the Swift target —
keeps both suites green while they describe two different state machines, which is precisely the
drift the fixture was written to catch, made invisible.

`Tests/Conformance/check-single-fixture.sh` is that invariant as a gate rather than a comment. It
reads the git index (no toolchain, no build) and fails on three things: a second tracked file named
`vectors.json`; any other tracked `*.json` containing the vector id `row-01-enqueue`, which catches
a copy that was renamed on the way in; and either port no longer naming
`Tests/Conformance/vectors.json`, which catches a port quietly repointed at its own fixture without
deleting anything.

## A skipped check is not a passing check

`.chief/verify.sh` reports **three** outcomes, not two:

| Outcome | Meaning |
|---|---|
| `PASS` | The check ran and succeeded. |
| `FAIL` | The check ran and did not. |
| `SKIPPED` | The check **never ran**. The target is *unverified* — this is not a pass. |

Every skipped check is also **named** in the run summary, under
`verify: SKIPPED checks — these did NOT run and are UNVERIFIED:`, and a run with any skip in it
ends with `nothing failed, but N check(s) never ran. This is NOT a full pass.` rather than the
`every check ran and passed` line, which only a fully-executed run can print. A count on its own
is not enough: "3 skipped" does not tell you that the *Android* build is the one nobody compiled.

### The two environments disagree, deliberately

This is the one place local and CI must not share a policy.

- **Local (default).** A developer machine legitimately lacks toolchains — Swift needs macOS, the
  Android build needs a JDK *and* the Android SDK, and neither is worth installing to change a
  README. A missing toolchain is a fact about the machine, not a defect in the branch: report
  `SKIPPED`, name it, exit `0`.
- **CI (strict).** The workflow installs every toolchain before any gate runs. A check that skips
  *there* means an install step silently broke, and a gate that cannot run is worth less than no
  gate at all, because it reports success. So in strict mode **a skip is a failure** and the run
  goes red.

Strict mode is selected automatically by `CI=true`, which GitHub Actions sets. `AMPHORA_VERIFY_STRICT=1`
or `=0` overrides it in either direction.

```sh
.chief/verify.sh                       # local: skips are reported and tolerated
CI=true .chief/verify.sh               # strict: skips are failures
AMPHORA_VERIFY_STRICT=1 .chief/verify.sh
```

### The counterfactual is a test, not a claim

`.chief/tests/verify-skip-policy.sh` runs the real `verify.sh` with an **emptied `PATH`**, so every
toolchain it probes for is genuinely absent — the "Android toolchain removed" condition, plus the
other two for free, at no build cost because nothing can run. It then asserts that:

1. locally the Gradle check reports `SKIPPED Gradle build: no JDK on PATH`, never `PASS`, the run
   exits `0`, and the summary names all four skipped checks;
2. under `CI=true` the same condition produces `FAIL Gradle build: SKIPPED (no JDK on PATH)` and a
   non-zero exit, with no bare `SKIPPED` line anywhere;
3. `AMPHORA_VERIFY_STRICT` overrides the environment in both directions.

The `verify-policy` job in `.github/workflows/ci.yml` runs it on every push, so the distinction
cannot be re-flattened without turning CI red.

### Known divergence: `verify.sh` is not identical to CI

Two gaps remain, and both are recorded rather than papered over:

- `verify.sh` runs `swift build --package-path ios`; CI runs it with `-Xswiftc -warnings-as-errors`.
  The `ios` job is currently red on a `Sendable` conformance error that the local command does not
  surface. Nothing in this repository owns that fix yet.
- `verify.sh` runs `./gradlew build`; CI runs `:android:assemble` and `:android:testDebugUnitTest`.

A green `verify.sh` therefore does not predict a green run. Check `gh run list` before believing a
branch is clean.
