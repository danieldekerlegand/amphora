# Environmental claim evidence

> **Status:** Evidence run · **Updated:** 2026-08-20 · **Owner:** Amphora

This ledger records what can be demonstrated from the repository and what still requires a
physical device. A simulator or emulator result is not promoted to device evidence for claims that
depend on OS suspension, process termination, storage pressure, foreground-service quotas, or radio
handoff.

## Evidence run

| Claim | Verdict | Evidence and observation |
|---|---|---|
| Background transfer continues while suspended | NOT YET VERIFIED — physical device | No device recording is checked in. iOS background `URLSession` and Android bounded `WorkManager` are the production paths; neither can be honestly validated by the host-side tests. Run the two-platform device procedure in the matrix before changing this verdict. |
| Process death, relaunch, resume, and cancel | AUTOMATED for protocol/state; NOT YET VERIFIED for OS relaunch | `swift run --package-path ios AmphoraTusdIntegration` and `android` `TusdIntegrationTest` each create an upload, acknowledge a partial offset, create a fresh client, read the server offset with `HEAD`, and append only the remainder. The iOS path test also observes cancelation deleting staged data and persisting `CANCELED`. This proves the durable protocol/state behavior, not an OS process-kill event. |
| Storage reclamation mid-transfer | AUTOMATED typed-failure path; NOT YET VERIFIED for real reclamation | `swift run --package-path ios AmphoraPathTests` observes `StorageError.pressureRose` and confirms the partial remainder is removed. The implementation stages in Application Support, not purgeable Caches. Real OS reclamation still needs a physical-device run under storage pressure. |
| Android `dataSync` budget exhaustion | AUTOMATED bounded-slice design; NOT YET VERIFIED for six-hour OS budget | `UploadWorker` limits each run to 8 minutes or 2 GiB, flushes the acknowledged offset from `onStopped()`, and maps `ForegroundServiceStartNotAllowedException` to `BLOCKED(FGS_QUOTA_EXHAUSTED)`. The Android instrumentation procedure must observe a real timeout and successor worker before this is a device claim. |
| Wi-Fi→cellular transition | AUTOMATED resumable protocol behavior; NOT YET VERIFIED for radio handoff | The transport resumes from `HEAD` after a transient failure, but no checked-in host test can cause a genuine radio handoff. A device recording must show the same upload URL, monotonic server offset, and final completion across the transition. |

## Required device recordings

For every device run, retain the raw log or screen recording and record device model, OS build,
app version, source kind, selected transport, start/end timestamps, interruption action, stable job
ID, server final offset, and final state. Replace only the corresponding matrix cell with
`MANUAL-ON-DEVICE — <evidence name>` after the observation is captured. Until then, keep the
cell `NOT YET VERIFIED` rather than substituting weaker simulator evidence.

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
