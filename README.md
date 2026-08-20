# Amphora

> **Status:** Draft · **Updated:** 2026-08-19 · **Owner:** Daniel DeKerlegand

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
```

## Status

Specification plus Android, iOS, and RN skeletons. Nothing moves bytes yet.

**iOS builds clean as of 2026-08-20** — `swift build` from `ios/`, zero errors and zero warnings.
It previously could not be built at all: there was no `Package.swift`, so "it does not compile"
was not a statement about the code, it was the absence of a project to compile. Adding the
manifest surfaced five real defects, since fixed — three redundant optional re-bindings where
`try?` had already flattened `store.get`'s `UploadJob?`, and two actor-isolated `StorageGovernor`
calls made without `await`. All five would have failed on iOS too.

**Android still has no build manifest** — no `build.gradle`, so the same "no project to compile"
gap remains there, on top of the unwritten symbols listed below. Nothing about the Kotlin has been
compiler-checked.

Implemented: both state-machine ports, both engines, both reconcilers, the wire layer in both
dialects (create / head / append / terminate), the governors' policy logic, the iOS
background-session delegate and task re-identification, and the RN control surface.

Stubbed: `UploadStore`'s SQLite backing (iOS), `PHAsset` export and remainder writing (iOS),
seekable `content://` opening and provider staging (Android). Android also still references
`AmphoraGraph`, `EnumConverters`, `UploadWorker.enqueueDelayed`, and a notification builder that
are not yet written — so the Android target cannot compile even once it has a `build.gradle`.

No conformance vectors yet. Until they exist, the two state-machine ports are only as aligned as
review makes them — that is the next thing worth doing.
