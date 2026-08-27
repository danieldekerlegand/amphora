# Amphora

> **Status:** Draft · **Updated:** 2026-08-27 · **Owner:** Daniel DeKerlegand

A resumable, backgroundable, storage-aware and network-aware uploader for very large files,
across **React Native · iOS/Swift · Android/Kotlin · web**.

> The name is a placeholder — the standardized vessel Mediterranean cargo shipped in. Rename
> freely; nothing depends on it yet.

## Why this exists

Off-the-shelf coverage is real but uneven, and it stops short in exactly the places that matter:

- **Web is solved** — `tus-js-client` and Uppy. This repository ships no web transfer code.
- **iOS is mostly solved** — native `URLSession` resumable uploads on iOS 17+, TUSKit below that.
- **Android is weak** — the official client is Java, v0.1.12, and brings no background layer.
- **React Native is empty** — the only tus binding has had no commits since 2023 and gets ~78
  npm downloads a month.
- **Storage awareness does not exist anywhere.** No client library — not tus, not the AWS SDKs,
  not the commercial vendors — reasons about device free space. That gap is what corrupted
  uploads under `TransferUtility` when iOS reclaimed the app's cache mid-transfer.

So: **adopt the protocol, build the clients.**

## Adopted, not built

| Layer | What we use |
|---|---|
| Wire protocol | `draft-ietf-httpbis-resumable-upload` (tus 2.x lineage), interop version pinned |
| Server | tusd v2 with the S3 backend |
| Web client | `tus-js-client` / Uppy, unmodified |
| iOS transport | native `URLSession` resumable upload (iOS 17+); TUSKit as the pre-17 fallback |
| Storage backend | S3 multipart, as tusd's implementation detail rather than our concern |

## Built here

- **One state machine**, specified in [`docs/reference/state-machine.md`](docs/reference/state-machine.md)
  and ported to Kotlin and Swift, running shared conformance vectors so the platforms cannot drift.
- **A durable job registry plus a launch reconciler** — the answer to "close the app, reopen it,
  find the upload still there and still cancelable."
- **A storage governor** — the piece nothing off-the-shelf has. On Android it genuinely
  *reserves* space via `StorageManager.allocateBytes`; on iOS it checks
  `volumeAvailableCapacityForImportantUsage` and stages into Application Support rather than the
  purgeable `Caches`.
- **An Android background layer** — bounded WorkManager slices over a durable offset, designed
  around Android 15's 6h/24h `dataSync` foreground-service budget.
- **A React Native TurboModule** that is a *control surface only*. No transfer logic in JS,
  because JS does not run while the app is suspended. The package declares React Native `>=0.76.0`
  as a peer dependency because that is the minimum supported line with the TurboModule codegen
  surface used here.

## The design commitment that retires the original bug

**No chunk temp files.** Byte ranges stream out of the source file. Peak extra storage goes from
~2× file size to ~0, which removes the failure mode rather than working around it. A copy is
staged only when the source genuinely cannot be seeked (`PHAsset`, some Android content
providers), and only then does a storage reservation come into play.

## Layout

```
docs/reference/          the specification — behaviour lives here, not in platform code
docs/guides/             host-app integration
android/                 Kotlin: state machine, Room registry, governors, WorkManager slices
ios/Sources/Amphora/     Swift: state machine port, background session, two transports, governors
packages/react-native/   TurboModule spec and JS control surface
Tests/Conformance/       vectors.json — ONE file, read by both ports — plus the drift control
integration/tusd/        the real-wire harness: tusd v2 + MinIO via Docker Compose
```

Working in this repository: [`CLAUDE.md`](CLAUDE.md) covers what a session needs and cannot derive
from the tree — the no-chunk-temp-files commitment, why a `SKIPPED` check is not a passing one, why
`swift test` reports "no tests found" while the suite is fine, and the adopt-the-protocol boundary.
What has changed and when is in [`CHANGELOG.md`](CHANGELOG.md); nothing is released yet.

## Status

Specification, both platform ports, and the RN control surface — and, as of
**2026-08-27, bytes move.**

Both ports have completed a real upload against a real tusd v2 + S3 server, each across a real
interruption rather than a simulated one:

- **Swift**, locally against the Compose stack (`integration/tusd/swift-wire.sh`, exit 0): 8 MiB
  split across a genuine process death — `kill(getpid(), SIGKILL)`, observed exit status 137 — with
  a second OS process handed nothing but the upload URL resuming from server offset 5505024 and
  completing at 8388608. The object read back out of MinIO matched the source by SHA-256.
- **Kotlin**, in CI (run `33044191974`, job `android`): 8 MiB across an aborted `PATCH` — the
  production `SliceDeadlineReached` path, with `Content-Length` outstanding — resumed by a brand-new
  client from server offset 6553600, checksum verified.
- **The no-chunk-temp-files claim is now measured, not read off the source.** Peak extra disk during
  an 8 MiB transfer: **4 KiB** (Swift) and **0 KiB** (Kotlin). A remainder-staging transport would
  have needed roughly 2816 KiB.

Before that date this repository had never moved a byte, and for a week it said otherwise: tasklist
`80` recorded a live-run story as passing while its own notes said the Docker daemon was
unavailable. That record has been corrected, and the rule it broke is written down in
[The verification record](docs/reference/verification-record.md).

**iOS builds clean as of 2026-08-20** — `swift build` from `ios/`, zero errors and zero warnings.
It previously could not be built at all: there was no `Package.swift`, so "it does not compile"
was not a statement about the code, it was the absence of a project to compile. Adding the
manifest surfaced five real defects, since fixed — three redundant optional re-bindings where
`try?` had already flattened `store.get`'s `UploadJob?`, and two actor-isolated `StorageGovernor`
calls made without `await`. All five would have failed on iOS too.

**Android has a Gradle library manifest** with the Room, WorkManager, coroutines, OkHttp, and
AndroidX dependencies used by the Kotlin sources. The graph, Room enum converters, delayed retry
work, and `dataSync` foreground notification are also implemented. The target is configured for
JDK 17, Android SDK Platform 35, and Android Gradle Plugin 8.6.1; the local authoring machine lacks
Gradle and the Android SDK, so the Android build still needs to run in CI or an Android
 development environment.

Implemented: both state-machine ports, both engines, both reconcilers, the wire layer in both
dialects (create / head / append / terminate), the governors' policy logic, the iOS
background-session delegate and task re-identification, and the RN control surface.

**Nothing in this repository is stubbed.** The three that were — `UploadStore`'s SQLite backing and
`PHAsset` export plus remainder writing on iOS, seekable `content://` opening plus provider staging
on Android — were closed by tasklists `60` and `70` and are real code:
[`Store/SQLiteUploadStore.swift`](ios/Sources/Amphora/Store/SQLiteUploadStore.swift),
[`Governor/StorageGovernor.swift`](ios/Sources/Amphora/Governor/StorageGovernor.swift) (`writeRemainder`,
`exportPhotosAsset`), and both ports' `SourceResolver` with the Android
[`store/`](android/src/main/kotlin/dev/amphora/store) package behind it.

What is missing is an absence rather than a stub: `packages/react-native` declares the codegen spec
`AmphoraSpec`, and nothing on either native side implements it — no `RCTBridgeModule`, no
`ReactContextBaseJavaModule`, no podspec, no Gradle module for the package. The control surface
typechecks, builds, and is wired to no bytes. That is
[roadmap phase 6](ROADMAP.md#phase-6--host-adoption-via-the-react-native-turbomodule).

**The conformance vectors exist and both ports run them.** `Tests/Conformance/vectors.json` is one
file — 40 transition rows plus 3 transport rows — read by Swift and Kotlin alike, and both suites
run in CI. `Tests/Conformance/drift-control.sh` is the negative control that proves the suite would
catch a divergence rather than merely report agreement. Scope, including what the vectors do *not*
cover, is in [Conformance vectors](docs/reference/conformance-vectors.md).

The real-wire tusd v2 + S3 environment and opt-in Swift/Kotlin integration checks live in
[`docs/guides/tusd-integration.md`](docs/guides/tusd-integration.md).

**What is still unverified is the larger half.** All 40 cells of the device matrix read
`NOT YET VERIFIED — physical device`, the CI gate is currently red, and the React Native control
surface is bound to no native implementation. [`ROADMAP.md`](ROADMAP.md) states the measured
position cell by cell, names the phases that remain, and records the non-goals — including the
no-chunk-temp-files commitment — and the open decisions.

## Licence

**MIT** — see [`LICENSE`](LICENSE).

Chosen because this is a library meant to be embedded in other people's applications, including
closed-source ones, so any reciprocal term would be a barrier to the adoption that is the whole
point. Nothing in the dependency graph pulls a copyleft obligation inward: the iOS target has no
external dependencies at all, the Android dependencies are Apache-2.0, and the protocol is
implemented from the IETF draft rather than vendored from anyone. The reasoning, the audit it rests
on, and the file-level convention (root `LICENSE` plus SPDX in each distributable manifest, no
per-file headers) are in [Licensing](docs/reference/licensing.md).
