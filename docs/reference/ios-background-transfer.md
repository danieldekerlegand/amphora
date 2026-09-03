# iOS background transfer

> **Status:** Draft · **Updated:** 2026-09-03 · **Owner:** Daniel DeKerlegand

iOS is the platform where the OS does the most for us and permits the least improvisation.
Everything below follows from one fact: **the transfer is run by a system daemon, not by our
process.** We schedule work and receive callbacks; we do not drive a loop.

---

## 1. One session, stable identifier, created at launch

`BackgroundSessionManager` owns exactly one `URLSession` built with
`URLSessionConfiguration.background(withIdentifier:)`, and creates it eagerly in `init` rather
than on first use. Three consequences:

- Two live sessions sharing an identifier is a runtime error.
- A changing identifier orphans every in-flight task — permanently, since the tasks belong to the
  old identifier and nothing can enumerate them again.
- The session must exist **before** events arrive. iOS may relaunch the app specifically to
  deliver background events, and anything replayed before the delegate exists is lost.

Background sessions also constrain the API surface: **`uploadTask(with:fromFile:)` only.** Data
bodies and streamed requests are unsupported, and completion handlers are unavailable because the
app can be terminated between starting a task and its completion — a closure has nowhere to live.
Delegate callbacks are the only channel.

`urlSessionDidFinishEvents(forBackgroundURLSession:)` must invoke the handler the app delegate
stored. Skipping it does not raise an error; iOS simply deprioritises and then stops relaunching
the app, and uploads quietly stop progressing. See
[`guides/ios-host-integration.md`](../guides/ios-host-integration.md).

---

## 2. Identifying a task after relaunch

Task *objects* do not survive relaunch — the session recreates them, so object identity and any
associated state are gone. What survives:

- `taskIdentifier` — same value as before
- `originalRequest.url` — same URL
- `taskDescription` — an arbitrary string we control

So `startUpload` stamps `taskDescription = job.id` and persists `taskIdentifier` on the row. The
reconciler matches on either. This pair is the entire basis of the adopt path; without it, a
relaunched app can see that *some* upload is running but not *which*.

A task with no `taskDescription` is cancelled on sight. An unattributable task is worse than
useless — it keeps writing to an upload URL we no longer track, and it will race whatever we
start to replace it.

---

## 3. Two transports, chosen by OS version

| | iOS 17+ (`NativeResumableTransport`) | Pre-17 (`TUSKitTransport`) |
|---|---|---|
| Resumption | OS-native, implements the IETF draft | manual, via `Upload-Offset` |
| Background resume | automatic, no app code | requires a remainder file on disk |
| Peak extra storage | **0** | up to 1× remaining bytes |
| Interrupt behaviour | resumes at offset | pre-17 OS retries **from the beginning** |

On iOS 17+, `URLSession` negotiates support via `Upload-Complete`, handles the `104 Upload
Resumption Supported` handshake, and on a background session resumes across interruptions with no
app code running. `cancelByProducingResumeData()` gives a resume blob for explicit pause; a failed
upload can carry one in `URLError.uploadTaskResumeData`, which we persist **before** reporting the
error, since its presence means "resumable" rather than "start over".

We hand the system the original file and it manages the offset internally. No chunk files, no
remainder files, no staging — the configuration that structurally cannot reproduce the original
corruption bug, because there is nothing on disk for the OS to reclaim.

---

## 4. The pre-iOS-17 compromise, stated plainly

Below iOS 17 the system has no concept of an upload offset. A background task sends a whole file.
Therefore resuming at byte *N* in the background requires a file that *begins* at byte *N* — a
materialised remainder.

That contradicts state-machine **I6** ("no chunk temp file outlives a transport attempt"), and I6
exists precisely because staged files under storage pressure are what corrupted uploads before.
`TUSKitTransport` does not get to ignore it, so it is constrained:

- Remainders are staged **only** when background transfer is genuinely required. Foreground
  transfers stream ranges from the original file and stage nothing.
- Staging goes through `StorageGovernor` and holds a reservation for its lifetime. A refused
  reservation moves the job to `.blocked(.remainderStagingDenied)` — it waits for space rather
  than corrupting.
- Staging lands in **Application Support**, never `Caches`/`tmp`.
- Offset zero is special-cased: the original file *is* the body, so a first attempt costs nothing.

**The decision this hands you.** Setting the deployment target to **iOS 17** deletes
`TUSKitTransport`, the remainder-staging path, and `BlockReason.remainderStagingDenied` outright —
and with them the only iOS code path that can still be defeated by low storage. It deletes no
*dependency*: despite the name, `TUSKitTransport` does not import TUSKit and `ios/Package.swift`
declares no external packages at all. The name records the role the file plays, and the ~40 lines
of `Tus10Dialect` are what replaced the library. iOS 17 shipped in September 2023. Unless the host
app must support iOS 16, taking that target is the single highest-leverage simplification available
in this repository — and it has an ADR slot reserved, `0002-ios-deployment-target.md`.

---

## 5. Storage: placement is the mitigation

iOS has no `allocateBytes` equivalent — space cannot be reserved, only measured. So the defence is
placement plus vigilance:

- **Application Support, never `Caches` or `tmp`.** Apple's guarantee that `Caches` survives
  "while your app is running" does not cover a *suspended* app, which is exactly the state a
  background upload runs in. This one placement decision is the direct fix for the original bug.
- `volumeAvailableCapacityForImportantUsage` for headroom checks — the value intended for content
  the user asked for, not the opportunistic-prefetch figure.
- Mark staged files `isExcludedFromBackup`; they are reproducible from the source and should not
  consume the user's iCloud quota.
- Re-sample during long writes. `PHAsset` export of a large 4K video takes minutes, and free space
  can collapse underneath it.

`PHAsset` is the one source kind that *always* costs a full copy — Photos assets are not seekable
file URLs. It is also the case most likely to hit an iCloud-offloaded original, so export needs
`isNetworkAccessAllowed = true` and must be cancelable.

---

## 6. Division of labour with the system

Worth being explicit, because it is easy to duplicate work the OS already does:

| Concern | Owner |
|---|---|
| Waiting for connectivity | **iOS.** Background sessions always wait; `waitsForConnectivity` is ignored |
| Retrying after interruption | **iOS**, at increasing intervals |
| Resuming at an offset (17+) | **iOS** |
| Whether cellular / Low Data Mode is acceptable | **us** — `NetworkGovernor` + `UploadPolicy` |
| Whether there is disk space | **us** — `StorageGovernor` |
| Pause / cancel / retry semantics | **us** — `UploadStateMachine` |
| Which job a resurrected task belongs to | **us** — `taskDescription` + `taskIdentifier` |

`isDiscretionary = true` in release lets the system pick a good moment for large transfers; it is
forced `false` under `#if DEBUG`, because otherwise the system may defer uploads for hours and
nothing is testable.

**No `UIBackgroundModes` entry is required.** Background `URLSession` transfers are run by a
system daemon, not by app background execution. Adding `fetch` or `processing` and concluding they
are what makes uploads work is a common and misleading misconfiguration.

---

## Corrections

**2026-09-03, tasklist `901-docs-tell-the-truth`.** Read against
`ios/Sources/Amphora/Session/BackgroundSessionManager.swift`,
`ios/Sources/Amphora/Transport/WireDialect.swift`, `TUSKitTransport.swift` and `Package.swift`.
§1, §2, §5 and §6 all held — including the two that are easy to get backwards: the session really
is forced into existence in `init` (`_ = session`, not left lazy), and `isDiscretionary` really is
`false` under `#if DEBUG` and `true` otherwise.

Two did not:

- **§3 said iOS 17 negotiates support via `Upload-Incomplete`. The header is `Upload-Complete`.**
  `Upload-Incomplete` is the spelling from an early revision of the draft; interop version 8, which
  this repository pins, uses `Upload-Complete: ?1` / `?0`. Both dialects send it
  (`WireDialect.swift:81`, `WireDialect.kt:71,77`), `wire-protocol.md` documents it correctly, and
  `NativeResumableTransport.swift:42` says `Upload-Complete` in its own doc comment. This file and
  [platform-constraints.md §1](platform-constraints.md) were the last two places carrying the old
  name; both are fixed.
- **§4 said moving to iOS 17 would delete "the TUSKit dependency".** There is no TUSKit dependency
  and there never was one in this tree — [licensing.md](licensing.md) states it explicitly under
  *Adopted, not vendored*, and `Package.swift` declares zero external packages. Two documents, one
  fact, disagreeing; the licensing audit is the one that was read off the manifest, so it wins.
