# Environmental claim evidence

> **Status:** Evidence run · **Updated:** 2026-09-03 · **Owner:** Amphora

This ledger records what can be demonstrated from the repository and what still requires a
physical device. A simulator or emulator result is not promoted to device evidence for claims that
depend on OS suspension, process termination, storage pressure, foreground-service quotas, or radio
handoff.

## Evidence run

| Claim | Verdict | Evidence and observation |
|---|---|---|
| Background transfer continues while suspended | NOT YET VERIFIED — physical device | No device recording is checked in. iOS background `URLSession` and Android bounded `WorkManager` are the production paths; neither can be honestly validated by the host-side tests. Run the two-platform device procedure in the matrix before changing this verdict. |
| Process death, relaunch, resume, and cancel | AUTOMATED for protocol/state; NOT YET VERIFIED for OS relaunch | The two harnesses interrupt differently and are worth naming separately. **Swift** (`integration/tusd/swift-wire.sh`, driving `AmphoraTusdIntegration`): a process uploads a prefix and then calls `kill(getpid(), SIGKILL)` on itself; the driver asserts exit status **137** so a clean exit cannot pass for an interruption, and a *second, separate process* — given nothing but the upload URL — recovers the offset with `HEAD` and finishes. **Kotlin** (`TusdIntegrationTest`): a `PATCH` is aborted mid-body by `SliceDeadlineReached`, then a new `OkHttpClient` and `TusTransport` read the server offset and append only the remainder. The iOS path test also observes cancelation deleting staged data and persisting `CANCELED`. Real process death is therefore covered on the Swift side; what remains unverified is an **OS-initiated** kill and relaunch, which neither harness can cause. |
| Storage reclamation mid-transfer | AUTOMATED typed-failure path; NOT YET VERIFIED for real reclamation | `swift run --package-path ios AmphoraPathTests` observes `StorageError.pressureRose` and confirms the partial remainder is removed. The implementation stages in Application Support, not purgeable Caches. Real OS reclamation still needs a physical-device run under storage pressure. |
| Android `dataSync` budget exhaustion | AUTOMATED bounded-slice design; NOT YET VERIFIED for six-hour OS budget | `UploadWorker` limits each run to 8 minutes (`SLICE_DURATION_MS`) or 2 GiB (`SLICE_BYTE_CEILING`), flushes the acknowledged offset and releases the lease from a `finally` block wrapped in `withContext(NonCancellable)` — `CoroutineWorker` declares `onStopped()` final and expresses the stop as cancellation of `doWork`'s coroutine, so `NonCancellable` is what keeps those two suspending calls from returning immediately — and maps `ForegroundServiceStartNotAllowedException` to `BLOCKED(FGS_QUOTA_EXHAUSTED)`. The Android instrumentation procedure must observe a real timeout and successor worker before this is a device claim. |
| Wi-Fi→cellular transition | AUTOMATED resumable protocol behavior; NOT YET VERIFIED for radio handoff | The transport resumes from `HEAD` after a transient failure, but no checked-in host test can cause a genuine radio handoff. A device recording must show the same upload URL, monotonic server offset, and final completion across the transition. |

## Required device recordings

The field list a recording must carry, and the rule for promoting a cell, have one home:
[Environment verification matrix § Evidence required to close a cell](environment-matrix.md#evidence-required-to-close-a-cell).
It lives there because it is a property of the cells, and this file's rows are per-claim rather than
per-cell. The part that belongs here is the constraint it exists to enforce: until a recording is
captured, a cell stays `NOT YET VERIFIED` rather than being filled with weaker simulator evidence.

## Reproduction commands

From the repository root:

```sh
swift build --package-path ios
swift run --package-path ios AmphoraPathTests
swift run --package-path ios AmphoraTusdIntegration
```

The tusd integration command requires the configured local tusd endpoint. Android unit and
instrumentation checks require the Android SDK and Gradle toolchain; the repository's verification
script reports them as skipped when those tools are unavailable.

## Corrections

**2026-09-03, tasklist `901-docs-tell-the-truth`.** This file and
[the matrix](environment-matrix.md) were the two documents the previous pass (US-2) did not read;
both were still stamped `2026-08-20`. Read here against `android/src/main/kotlin/dev/amphora/work/UploadWorker.kt`,
`ios/Tests/AmphoraTusdIntegration/main.swift`, `integration/tusd/swift-wire.sh` and
`android/src/test/kotlin/dev/amphora/TusdIntegrationTest.kt`.

- **The `dataSync` row said `UploadWorker` "flushes the acknowledged offset from `onStopped()`".**
  It cannot: `CoroutineWorker` declares `onStopped()` final, which is why the class expresses the
  stop as cancellation of `doWork` and flushes from a `finally` block under
  `withContext(NonCancellable)` instead. The 8 minute / 2 GiB bounds either side of that sentence
  were correct and are now named as the constants that carry them. A reader who went looking for the
  override would have found no such method and had no way to know whether the doc or the class was
  wrong.
- **The process-death row *under*-claimed what the Swift harness proves.** It described both
  harnesses as creating "a fresh client", which is true of the Kotlin test and not of the Swift one:
  that driver `SIGKILL`s the uploading process and resumes in a genuinely separate process, asserting
  exit status `137` so that a clean exit cannot be mistaken for an interruption. The verdict does not
  change — an OS-*initiated* kill is still unverified — but the evidence cell now says which kind of
  interruption each side actually causes.
- **The device-recording field list was stated twice, here and in the matrix, in slightly different
  words.** The two agreed, which is the failure mode that survives review; it is now stated once, in
  the matrix, with a pointer from here.

**What this pass did not check.** It did not run either integration harness — both are opt-in on
`TUSD_ENDPOINT` and neither ran on this machine, so the evidence cells are read off the harness
*source*, not off an execution of it. It also did not re-derive the verdicts themselves: every row
still reads `NOT YET VERIFIED` for the environmental half, and nothing in this pass moved a cell in
either direction.
