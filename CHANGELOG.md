# Changelog

> **Status:** Live · **Updated:** 2026-09-12 · **Owner:** Daniel DeKerlegand

Notable changes to Amphora. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project intends [Semantic Versioning](https://semver.org/spec/v2.0.0.html) from `0.x`, with
the API surface explicitly unstable until it does not need to be.

**There are no releases yet, and that is deliberate rather than an oversight.** No git tag exists, no
artifact has been published to npm, Maven Central or by SwiftPM tag, and no host application has
adopted this. Publication is [`ROADMAP.md` phase 7](ROADMAP.md#phase-7--publication) and is gated on
the phases before it — chiefly a CI gate that is green rather than red, and device evidence for a
*background* uploader whose background behaviour has never run on hardware. So every entry below sits
under `[Unreleased]`, subdivided by the date the work landed on `main`.

Two conventions, both consequences of how this repository treats evidence
([The verification record](docs/reference/verification-record.md)):

- **An entry says what was observed, not what was intended.** Where a change was verified only in one
  environment, the entry says so rather than rounding it up.
- **Entries dated before 2026-08-27 were reconstructed** from git history and the tasklist records in
  `tasks/chief/completed/`, because this file did not exist while that work was done. They are
  therefore coarser than entries written as the work lands, and one of them (`80`, below) records a
  correction rather than the original claim.

---

## [Unreleased]

### 2026-09-12

#### Fixed

- **Two staging defects, one per port, neither of which any vector could have caught.** (1) **Swift
  never staged a `ph://` asset.** `SourceResolver.stageIfRequired` had **zero** callers for the whole
  life of the port while 40 conformance vectors reported green, so every Photos job reached the
  background session as `URL(fileURLWithPath: "ph://…")` — a file URL whose path is the literal
  scheme string. `DefaultUploadEngine.startTransfer` now calls it in the create-on-first-run branch,
  **before** `.sourceResolved` and **before** `transport.create` (the order Kotlin's `prepare()`
  already used: a reservation refused after `create` has already orphaned a server resource), with
  `TransportError.remainderStagingDenied` and `StorageError.stagingDenied` mapping to
  `.spaceDenied(needed:)` and every other failure falling through to the existing transport-error
  catch. (2) **Kotlin blocked every seekable content provider.** `prepare()` read a `null` from
  `stageIfRequired` — which means "seekable, stream it" — as a refusal, so a provider that streams
  with zero copies was dispatched `SpaceDenied` and left `BLOCKED(STORAGE_LOW)` every time. This one
  was read from the source while the tasklist was being written and **confirmed by running it red**:
  run `34677029934`, `android` job, `stage-02-seekable-source-not-staged: the remote was created
  expected:<true> but was:<false>`. A genuine refusal now arrives only as
  `StorageReservationDenied`. Both defects sat in the one step the fixture could not see — `vectors`
  is a pure-function suite over `reduce` and reaches neither engine's preparation step — so the fix
  includes the check that would have caught them: a third fixture section, `sourceStaging`
  (`schemaVersion` `2` → `3`), three rows run by **both** ports through the engine's own preparation
  step rather than by calling `stageIfRequired` directly, and one drift control per port that
  removes the engine's staging call and requires `stage-01-unseekable-source` to name it. Supporting
  seams, both introduced to make the decision testable without a device: `PhotosAssetSource` on
  Swift (the only file that imports `Photos`; the export is *told* its destination, so no
  implementation can choose `Caches`) and `ContentSource` on Kotlin (the mockable `android.jar`
  answers `Os.lseek` with `0`, so every provider would otherwise read as seekable). Observed on
  RUN_ID_PLACEHOLDER. **Scope, stated rather than implied:** every source and allocator in these rows
  is a double. They prove *our* call order and bookkeeping, not `PHAssetResourceManager` export
  behaviour, not an iCloud-offloaded original, not `StorageManager.allocateBytes` under real
  pressure. The device row **iOS / Photos asset** stays `NOT YET VERIFIED — physical device`.

- **Every CI job is green on one run id, for the first time in this repository's life — on a branch,
  not on `main`.** Run `34675666580` (head `3b6f934`, `chief/140-ci-green-at-the-root`), **both
  attempts on the identical sha**: `ios`, `android`, `conformance-fixture`, `verify-policy` and
  `react-native` all `success`. Two attempts rather than one because this gate has flipped its verdict
  on unchanged input before, and one green run after a red one proves nothing about the input. The
  `ios` job reached its later steps for the first time ever — it used to die at `swift build` — and
  printed `Amphora path tests: 46 passed (4 upload-path cases, 39 state-machine vectors, 3 I6
  transport vectors)` and `drift-control: 2 control(s) ran, 0 skipped, 0 failure(s)`. The `android`
  job's real wire ran end to end: `Kotlin real wire: 8 MiB uploaded across an aborted PATCH, resumed
  by a new client from server offset 6553600, checksum verified, peak extra disk 0 KiB`.
  **This does not close [`ROADMAP.md` phase 1](ROADMAP.md#phase-1--make-the-gate-total)**, whose exit
  condition names a run and which has only ever been tested on branches; chief merges locally and
  pushes nothing, so the `main` run is an operator step and phase 1 lists it.

- **MinIO is pulled from `quay.io` instead of Docker Hub, at the identical digest.** The `android`
  job's `Start tusd + MinIO` step failed on run `34675398053` with `pull access denied for
  minio/minio, repository does not exist or may require 'docker login'`. Docker Hub answers `401` for
  the pinned digest **and** for `latest` on `minio/minio`, while `tusproject/tusd` on the same
  registry answers `200` — so the repository stopped serving anonymous pulls; the digest had not
  rotted. quay.io returns the same `docker-content-digest` (`sha256:14cea493…8936e`) for the same
  `RELEASE.2025-09-07T16-13-09Z` tag, so `integration/tusd/docker-compose.yml` changed host and
  nothing else, provably. This is a second way a pin can stop resolving — the first was a withdrawn
  tag — and nothing in the tree detects either ahead of a red run; phase 3 still carries that.

- **The Room schema export race is fixed at the configuration, and the exported schema is now in
  version control.** `:android:kaptReleaseKotlin` had died with
  `java.lang.IllegalStateException: Empty schema file` on run `33044503283` and then passed on the
  next run whose input differed by one JSON tasklist file — a gate flipping its verdict on
  effectively unchanged input. The mechanism was established from the Room 2.6.1 sources before
  anything was changed: under the raw `room.schemaLocation` processor option, `Context.kt`
  resolves `schemaInFolderPath` and `schemaOutFolderPath` to the *same* directory, both variant
  kapt tasks (started 0.5 ms apart — `02:51:02.2888336Z` and `02:51:02.2893492Z` in run
  `34556064209`) read and write the one file
  `schemas/dev.amphora.store.UploadDatabase/1.json`, and `Database.exportSchema` serializes
  through `FileOutputStream(file, false)`, so the file is zero bytes for the width of a write and
  a concurrent reader gets Gson's `null` and the exception — `SchemaBundle.kt:69` <-
  `Database.kt:110`, the exact two frames of the observed stack. The fix is the Room Gradle Plugin
  (`id("androidx.room")` 2.6.1, the same version as `room-runtime`/`room-compiler`) with
  `room { schemaDirectory("$projectDir/schemas") }`; the `kapt { arguments { arg("room.schemaLocation", ...) } }`
  block is gone, because the two mechanisms together are an error in Room's own check
  (`INVALID_GRADLE_PLUGIN_AND_SCHEMA_LOCATION_OPTION`). The plugin gives each variant task its own
  output directory under `build/intermediates/room/schemas/<task>` and copies into the committed
  directory from a task both kapt tasks are `finalizedBy`, so no two writers share a target.
  `android/schemas/dev.amphora.store.UploadDatabase/1.json` is committed with the bytes Room
  itself wrote, retrieved from CI run `34675294998`, and a new `android` job step fails the build
  whenever the exported schema and the committed one differ — which is both how the file was
  retrieved and what stops a later entity change shipping without its schema. Observed on branch
  run `34675398053` (head `076d82d`): `:android:assemble` SUCCESS, the schema step SUCCESS
  (`android/schemas is clean: the exported schema equals the committed one`),
  `:android:testDebugUnitTest` SUCCESS with `ConformanceVectorsTest > sharedVectorsMatchAndroidPort
  PASSED` and `sharedI6VectorsHoldForTheAndroidTransport PASSED`, `> Task :android:copyRoomSchemas
  NO-SOURCE` (the steady state: an unchanged schema is not re-written, so there is nothing to
  copy), and **zero** log lines matching `room.schemaLocation` or `Schema export directory`. One
  warning survives on `:android:kaptDebugUnitTestKotlin`, quoted rather than called gone:
  `warning: The following options were not recognized by any processor: '[room.internal.schemaInput, room.internal.schemaOutput, kapt.kotlin.generated]'`
  — the plugin configures the unit-test component too, and no `kaptTest` processor is declared to
  claim the options. A green `android` job is deliberately **not** offered as the evidence here:
  that job was already green on the unchanged tree, and the ROADMAP's exit rule says a green run
  after a red one on unchanged input closes nothing. The evidence is the mechanism plus the
  configuration that removes it. kapt's `Kapt currently doesn't support language version 2.0+.
  Falling back to 1.9.` warning is untouched and out of scope.

- **`BackgroundSessionManager` has a concurrency model, and the `ios` CI job's two compile errors go
  away because of it.** The type carried two unguarded pieces of mutable state (`systemCompletionHandler`
  and a `lazy var session`) and no statement of which thread touched what, so the `ios` job had been
  red since its first run on `NetworkGovernor.swift:23` (`reference to captured var 'self'`) and
  `TUSKitTransport.swift:27` (`BackgroundSessionManager` not `Sendable` inside a `Sendable` struct) —
  meaning `swift run AmphoraPathTests` and the Swift drift control had never once executed in CI. Both
  mutable fields are now guarded by one `NSLock` (`NSLock` and not `OSAllocatedUnfairLock`: the package
  minimum is iOS 15), the session is created eagerly in `init`, the conformance is `@unchecked Sendable`
  with a per-property table justifying it, and `urlSessionDidFinishEvents` takes the system completion
  handler and clears it in a single critical section — which also fixes a latent double-call when two
  batches of events were replayed close together. `ROADMAP.md` §4 asked who owns this model; this is
  the answer.
- `NetworkGovernor.start()` binds `guard let self` before the `Task`, so the `Task` captures a `let`
  rather than the `var` a weak capture produces. The capture stays weak — the actor owns the
  `NWPathMonitor`, and `stop()` does not clear `pathUpdateHandler`, so a strong capture there is a
  retain cycle nothing breaks.
- `SQLiteUploadStore` hands its `sqlite3` handle to a small owning class whose own `deinit` closes it.
  An actor's `deinit` is nonisolated, so the previous `deinit { sqlite3_close(database) }` read a
  non-`Sendable` `OpaquePointer` from nonisolated code — an error in the Swift 6 language mode.
  **Swift: verified locally**; a clean build under `-Xswiftc -warnings-as-errors
  -Xswiftc -strict-concurrency=complete` now reports zero diagnostics where it reported two.

#### Removed

- `BackgroundUploadStarter`, the `@unchecked Sendable` wrapper struct that existed only because
  `BackgroundSessionManager` had no concurrency model to point at. `BackgroundUploadStarting` now
  refines `Sendable` directly and both transports store their session reference without a wrapper.

#### Changed

- `.chief/verify.sh` builds Swift with `-Xswiftc -warnings-as-errors`, the flag the `ios` job uses.
  This closes the *flag* half of the divergence in
  [Continuous integration § Known divergence](docs/reference/continuous-integration.md); the
  toolchain half cannot be closed locally, so the `ios` job gained a first step printing
  `swift --version` and `xcodebuild -version` to name the compiler behind the next one.

### 2026-09-03

#### Removed

- `UploadDao.inState` — a Room `@Query` whose only occurrence in the module was its own declaration.
  Room generates a query's implementation, never a caller, and it had no Swift counterpart, so it was
  not half of a deliberate cross-port registry API. **Kotlin: verified in CI only** — `Gradle build`
  reports `SKIPPED` on the authoring machine (no JDK on `PATH`).
- The `SDK_INT >= O` guard in `UploadNotifications.ensureChannel()` — `VERSION_CODES.O` is API 26 and
  `minSdk` is 26, so the condition held on every installable device and the `else` was unreachable.
  The sibling `>= Q` guard is live and stays. **Kotlin: verified in CI only.**
- The `androidx.core:core-ktx` dependency declaration — zero `import androidx.core` in the module. It
  stays on the resolved classpath transitively via `work-runtime-ktx`, so nothing a compile can
  observe changes. **Kotlin: verified in CI only.**

#### Changed

- `TransportError.errorClass` now defers to `HTTPStatus.classify` instead of restating the same
  six-arm HTTP-status → `ErrorClass` table verbatim. The two copies were read on different code paths
  — the background-session delegate and the foreground control plane — and no conformance vector
  covers status classification, so a change to one copy would have shipped a build that retries `429`
  on `HEAD` and gives up on it mid-transfer with all 40 vectors still passing. Observed: Swift build
  plus 46 passing cases, unchanged before and after.

#### Added

- [Dead-code inventory](docs/reference/dead-code-inventory.md) — nine reproducible searches and what
  each covers, six genuinely-dead findings, eight things that fail a static search and are
  nonetheless load-bearing, three intra-port duplications, and the four classes of thing a static
  search over this tree cannot see.
- [Dead-code removal record](docs/reference/dead-code-removal.md) — the disposition of every
  inventory row. Three of the six §1 candidates were **not** removed, each with its reason, and one
  of those three (`loadResumeData`) survived because the inventory's own corroborating grep result
  was wrong: the mechanism *is* specified, in `ios-background-transfer.md:65-66` and
  `platform-constraints.md:21-22`.
- [What the dead-code sweep could not decide](docs/reference/dead-code-undecidable.md) — the register
  of candidates the method could not resolve, all left in place, and the limits of the method itself.
  Working through the tree candidate by candidate found **six** blind-spot classes where the inventory
  had named four; the two it missed are symbols bound by string rather than by reference, and edges
  that exist only across a process boundary. Both occur here. Observed, and the reason the register
  exists: `BlockReason.powerLow` has **zero** references in *both* ports — the shape that marked
  `WireDialect.Rufh` as the strongest dead candidate in the tree — and is live, decoded by raw value
  from `"POWER_LOW"` in conformance vector `row-14-power-low`. Likewise `AmphoraUploader`, the entire
  public API of both platforms, is referenced nowhere outside the file that declares it; the searches
  that produced the inventory, applied honestly to it, would delete the library.

#### Changed

- [Dead-code inventory §4](docs/reference/dead-code-inventory.md) corrected in place, struck through
  rather than rewritten, on two points: its list of four blind spots was incomplete, and its
  reflection finding (*"no `Class.forName` … anywhere in the tree"*) was true as a grep result and
  misleading as a conclusion — the reflection that reaches this code lives in Room, WorkManager and
  `TurboModuleRegistry`, so searching this tree for it can only ever return zero.

#### Fixed

- **Nine reference documents were read back against the tree and corrected**, each carrying a dated
  `## Corrections` section saying what it had claimed, what the code says, and what was read to tell
  them apart. The substantive ones, in rough order of how badly they would have misled a reader:
  - [`state-machine.md`](docs/reference/state-machine.md) §3 — the **normative** event list named
    `SetPriority`, which exists in neither port, and six environment signals (`NetworkLost`,
    `StorageLow`, `PowerLow`, `StorageOk`, `NetworkAvailable`, `FgsQuotaExhausted`) of which five do
    not exist; both ports carry `Blocked{reason}` / `GateCleared` instead. It also omitted
    `Schedule`, `SourceResolved` and `SourceMissing` — all three of which its own §2 table already
    used — and listed five `TransportError` classes where both ports declare seven.
  - [`persistence-and-recovery.md`](docs/reference/persistence-and-recovery.md) §2 — the registry
    schema named `metadata` and `policy` (they are `metadataJson` and `policyJson`), a policy field
    `allowedNetworks` that does not exist, and a `sourceKind` domain neither port declares; it
    omitted `remoteTerminated`; and it stated an `upload_event` ring per job that **neither port
    implements**, now kept as a declared gap rather than a schema row.
  - [`ios-background-transfer.md`](docs/reference/ios-background-transfer.md) and
    [`platform-constraints.md`](docs/reference/platform-constraints.md) — both said iOS 17 discovers
    server support via `Upload-Incomplete`; the header is `Upload-Complete`, and had been in every
    dialect and in `wire-protocol.md` all along. Both also described TUSKit as a dependency of this
    repository, which [`licensing.md`](docs/reference/licensing.md) has always said it is not.
  - [`android-build.md`](docs/reference/android-build.md) — told the reader to run
    `gradle :android:assemble`, the unreproducible form that `gradle-wrapper.properties` and
    `.github/workflows/ci.yml` both carry a comment against.
  - [`licensing.md`](docs/reference/licensing.md) — the dependency audit still listed
    `androidx.core:core-ktx` as a declared Android runtime dependency after the sweep above deleted
    the declaration. Transitive and Apache-2.0 either way, so the licence conclusion is unchanged;
    the audit's reproducibility was not.
- **Three facts that were stated twice and disagreed** are now stated once, with the other side
  pointing at it: the count of pre-existing Swift-concurrency errors in the `ios` job (
  [`conformance-vectors.md`](docs/reference/conformance-vectors.md) said three,
  [`continuous-integration.md`](docs/reference/continuous-integration.md) said two — CI run
  `33044503283` says two); the pinned tusd version (`platform-constraints.md` said v2.10.0, the
  Compose digest pin and two other documents say v2.4.0); and whether TUSKit is a dependency.
- **The two documents that sweep missed**, both still stamped `2026-08-20`, read against the tree
  afterwards:
  - [`environment-evidence.md`](docs/reference/environment-evidence.md) — said `UploadWorker`
    "flushes the acknowledged offset from `onStopped()`". It cannot; `CoroutineWorker` declares
    `onStopped()` final, which is why the class flushes from a `finally` block under
    `withContext(NonCancellable)`. The same file *under*-claimed the Swift integration harness,
    describing it as creating "a fresh client" when it `SIGKILL`s the uploading process and resumes
    in a genuinely separate one.
  - [`environment-matrix.md`](docs/reference/environment-matrix.md) — placed the transport selector
    in `AmphoraUploader`, which contains no `#available` check at all. It is `TransportSelector.select`
    in `Transport/UploadTransport.swift`, and it picks the dialect along with the transport.
  - The device-recording field list, stated in both files in slightly different words, now has one
    home in the matrix. No matrix cell moved: all 40 still read `NOT YET VERIFIED — physical device`.

#### Added

- [The documentation sweep](docs/reference/documentation-record.md) — the record of the sweep
  itself, in three parts a diff cannot supply. **Nothing was archived and nothing was deleted**:
  `git log --diff-filter=D -- '*.md'` returns zero rows across all 100 commits, so `docs/archive/`
  does not exist and was not created empty to make a layout table look complete; the bar a document
  must clear to go there is stated now, while nothing is pressing on the judgement. Seven documents
  that look stale are kept deliberately, each with its reason — the dead-code inventory is the
  *approval* record its removal record cites row by row, and the environment ledgers are not stale
  for listing obligations that are unmet. And the limits: the reading was one-directional, so an
  omission would have survived it; the conformance fixture cannot check the prose, which is how the
  normative state machine drifted in the first place; no integration harness was run; and no JDK was
  present for any of it.

### 2026-08-27

#### Added

- `LICENSE` — **MIT**. The repository previously granted no permission to use it at all, while
  `packages/react-native/package.json` had declared `"license": "MIT"` since it was created; npm would
  have rendered a licence the repository did not carry. The reasoning, the dependency audit it rests
  on, and the file-level convention (root `LICENSE` plus `SPDX-License-Identifier` in each
  distributable manifest, no per-file headers) are in
  [Licensing](docs/reference/licensing.md).
- `ROADMAP.md` — the measured position as a fourteen-row evidence table, seven phases named for what
  remains, three non-goals, and the open decisions. Written *after* tasklists `100`–`120` ran so that
  it records a measured position rather than an intended one.
- `CLAUDE.md` — orientation for a session working here: the boundary, the no-chunk-temp-files
  commitment, the `SKIPPED`-is-not-`PASS` gate policy, and the `swift test` gotcha below.
- This `CHANGELOG.md`.
- **The first bytes this repository has ever moved**, on both ports, across real interruptions:
  - **Swift**, locally against the Compose stack (`integration/tusd/swift-wire.sh`, exit `0`): 8 MiB
    split by a genuine process death — `kill(getpid(), SIGKILL)`, observed exit status 137 — with a
    second OS process handed nothing but the upload URL resuming from server offset `5505024` and
    completing at `8388608`. The object read back out of MinIO matched the source by SHA-256.
  - **Kotlin**, in CI (run `33044191974`, job `android`): 8 MiB across an aborted `PATCH` on the
    production `SliceDeadlineReached` path with `Content-Length` outstanding, resumed by a brand-new
    client from server offset `6553600`, checksum verified.
- **The no-chunk-temp-files invariant (I6) is now measured rather than read off the source.** Peak
  extra disk during an 8 MiB transfer: **4 KiB** (Swift) and **0 KiB** (Kotlin); a remainder-staging
  transport would have needed ≈2816 KiB. Three transport vectors in `Tests/Conformance/vectors.json`
  observe the filesystem during an attempt and fail if any file materialises.
- `Tests/Conformance/drift-control.sh` — the negative control, committed as a script rather than
  performed once in prose. It puts a deliberate divergence into one port and requires that port's
  vectors to go **red** naming the vector that caught it, twice per port (transition table and I6).

#### Changed

- Both ports now locate `Tests/Conformance/vectors.json` without a working-directory-relative path —
  Swift walks up from `#filePath`, Kotlin uses the `amphora.repoRoot` system property. A fixture the
  runner could not find previously crashed with `NSCocoaErrorDomain 260`, which reads as a broken
  machine rather than as a red test; both ports now fail with the list of paths they searched.
- The Kotlin conformance suite runs **in CI**, against the same 40 transition rows and 3 transport
  rows as Swift. Before this, forty vectors that existed to stop two ports drifting had only ever run
  on one of them.

#### Fixed

- The real-wire harness runs again. The pinned MinIO tag `RELEASE.2024-06-13T19-44-55Z` had been
  withdrawn from the registry, so a pin that guaranteed reproducibility guaranteed nothing. Both
  images are now digest-pinned with the release in a comment, and the separate `minio/mc` pin was
  deleted outright (`mc` ships inside the MinIO image) — one fewer tag that can be withdrawn.
- `integration/tusd/run.sh` has an observed three-valued exit contract: live daemon → `0`;
  `DOCKER_HOST` at a nonexistent socket → `77` (SKIP); `docker` off `PATH` → `77`;
  `AMPHORA_REQUIRE_DOCKER=1` with no daemon → `1`.

#### Corrected

- **Tasklist `80`'s record.** Two stories had been marked passing while their own notes recorded that
  Android Gradle was unavailable and the Docker daemon unreachable — the run never happened. For a
  week this repository asserted an upload it had not performed. The record has been corrected, and the
  rule it broke is now written down in
  [The verification record](docs/reference/verification-record.md): a story may not be marked passing
  on work its own notes say did not run.

### 2026-08-26

#### Added

- **A git remote, and CI that actually executes.** `.github/workflows/ci.yml` had existed for weeks
  and had never run on any machine, which made every Android claim here *unfalsifiable* rather than
  false. The trigger is `push` on `main` and `chief/**`, because work is merged locally and pushed
  rather than delivered by pull request — a `pull_request`-only trigger would never have fired once.
  The repository is public deliberately; the reason is billing, and it is recorded in
  [Continuous integration](docs/reference/continuous-integration.md).
- **`.chief/verify.sh` reports three outcomes** — `PASS`, `FAIL`, and `SKIPPED` — where `SKIPPED`
  means the check never ran and the target is unverified. Locally a skip is tolerated and named; under
  `CI=true` a skip is a **failure**, because a gate that cannot run reports success.
  `.chief/tests/verify-skip-policy.sh` proves the two policies differ by running the real script with
  an emptied `PATH`, and the `verify-policy` CI job runs it on every push.

#### Fixed

- **The Kotlin port was compiled for the first time in this repository's history** (run
  `33039508625`, `:android:assemble` BUILD SUCCESSFUL, 54 tasks). The compiler immediately found five
  real defects that no amount of reading had found: a missing `room-ktx` dependency, a `Call.await()`
  called at four sites and never written, a missing import, and a `ParcelFileDescriptor.seekTo()` that
  does not exist.

### 2026-08-20

The specification, both platform ports, and the gates around them. Reconstructed from git history;
each item corresponds to a completed tasklist under `tasks/chief/completed/`.

#### Added

- Initial commit: the specification in `docs/reference/` plus platform skeletons.
- **Android** (`10`): a Gradle build manifest with the Room, WorkManager, coroutines, OkHttp and
  AndroidX dependencies the Kotlin sources use, and the four symbols the sources referenced but that
  had never been written.
- **React Native** (`20`): `@amphora/react-native` builds and typechecks, plus
  `scripts/check-control-surface.js` — a guard that keeps transfer logic out of JavaScript, because JS
  does not run while the app is suspended.
- **iOS** (`30`): a concrete SQLite-backed `UploadStore`, a constructible object graph, and the
  offset-zero upload path end to end.
- **Gates** (`40`): `.chief/verify.sh` builds and tests every target it can reach; CI builds all three.
- **Conformance vectors** (`50`): one language-neutral fixture derived from the spec, read by both
  ports, with a divergence failing the build.
- **iOS sources completed** (`60`): `writeRemainder` streams from the source and re-samples storage
  pressure; `PHAsset` export writes its staged copy under a reservation. Both had been stubs.
- **Android sources completed** (`70`): a seekable `content://` source streams without staging;
  non-seekable providers stage under a real `StorageManager.allocateBytes` reservation. Both had been
  stubs.
- **The environment matrix** (`90`): `docs/reference/environment-matrix.md`, 10 rows × 4 interruption
  columns, every cell carrying a verdict and the evidence it was read from — and explicitly recording
  that all 40 read `NOT YET VERIFIED — physical device`, because no simulator result is ever
  substituted for a hardware one. `docs/reference/environment-evidence.md` records what automated
  evidence exists per environmental claim and what it does not cover.

#### Fixed

- **The iOS target had no build manifest**, so "it does not compile" was not a statement about the
  code — there was no project to compile. Adding `ios/Package.swift` surfaced five real defects, since
  fixed: three redundant optional re-bindings where `try?` had already flattened `store.get`'s
  `UploadJob?`, and two actor-isolated `StorageGovernor` calls made without `await`. All five would
  have failed on iOS too.

---

## Known-red at the time of writing

Recorded here rather than left for a reader to discover, and stated in full in
[`ROADMAP.md` §1](ROADMAP.md#1-where-this-actually-is--2026-08-27):

- **The CI gate is red.** Latest run `33044503283` (head `f769a6f`): `react-native`,
  `conformance-fixture` and `verify-policy` SUCCESS; **`ios` FAILURE** (two Swift concurrency errors)
  and **`android` FAILURE** (`:android:kaptReleaseKotlin` → `Empty schema file`, which is
  *nondeterministic* — the same job was SUCCESS at `89583f9`, and the diff between them is one JSON
  tasklist file).
- **The Swift real-wire run is local-only.** The `ios` job dies at compile, so `swift run
  AmphoraPathTests` and the Swift drift control never execute in CI.
- **Every Android claim rests on CI alone**, because the authoring machine has no JDK and `Gradle
  build` reports `SKIPPED` there.
- **The React Native package is bound to no native implementation.** It declares the codegen spec
  `AmphoraSpec`; nothing on either native side implements it, and there is no podspec or Gradle module
  for the package.
