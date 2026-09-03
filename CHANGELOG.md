# Changelog

> **Status:** Live · **Updated:** 2026-09-03 · **Owner:** Daniel DeKerlegand

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
