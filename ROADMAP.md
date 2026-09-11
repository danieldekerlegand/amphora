# Amphora roadmap

> **Status:** Live · **Updated:** 2026-09-11 · **Owner:** Daniel DeKerlegand

This document states **where this repository actually is**, then what remains, in the register
[`docs/reference/environment-matrix.md`](docs/reference/environment-matrix.md) already uses: a cell
is a verdict plus the evidence it was read from, and a cell with no honest evidence stays
`NOT YET VERIFIED` rather than being upgraded to make the table look finished. A simulator result
is never substituted for a hardware one, here or anywhere else in this tree.

Nothing below carries a date. Dates would be intentions; this repository has already paid once for
recording an intention as a result (see [The verification record](docs/reference/verification-record.md)).
Phases are ordered by dependency, and each states the observation that would close it.

---

## 1. Where this actually is — 2026-08-27

The same three labels the matrix uses: **AUTOMATED** (reproduced by a checked-in command, named in
the cell) · **MANUAL-ON-DEVICE** (reproduced on physical hardware, recording named) ·
**NOT YET VERIFIED** (no honest evidence exists).

| Claim | Verdict | Evidence, or the reason there is none |
|---|---|---|
| The Swift port moves bytes across a real wire, across a real interruption | **AUTOMATED — local only** | `integration/tusd/swift-wire.sh` exit `0` against Docker server 29.3.1: 8 MiB split by `kill(getpid(), SIGKILL)` (observed exit status 137), a second OS process handed only the upload URL resuming from server offset `5505024` and completing at `8388608`, object read back out of MinIO matching the source at sha256 `bdf23837…`. **Not in CI** — see phase 3. |
| The Kotlin port moves bytes across a real wire, across a real interruption | **AUTOMATED — in CI** | Run `33044191974`, job `android`: `TusdIntegrationTest > completesAcrossAnAbortedRequestAndStagesNothingOnDisk PASSED`. 8 MiB across an aborted `PATCH` on the production `SliceDeadlineReached` path with `Content-Length` outstanding; a brand-new client re-established offset `6553600` by `HEAD`; checksum verified. |
| **I6 — no chunk temp files** holds in practice, not just in the source | **AUTOMATED (measured)** | Peak extra disk during an 8 MiB transfer: **4 KiB** Swift (sampled `du -sk` every 50 ms with `TMPDIR` redirected into the sampled tree; baseline 8192 KiB, peak 8196 KiB) and **0 KiB** Kotlin (per-run `java.io.tmpdir`, 25 ms sampling). A remainder-staging transport would have needed ≈2816 KiB. |
| The two state machines do not drift | **AUTOMATED — partial** | One fixture, `Tests/Conformance/vectors.json`, `schemaVersion 2`, 40 transition rows + 3 transport rows, read by both ports in CI, with `check-single-fixture.sh` gating the one-file invariant. Drift is *proven caught*, not assumed: `Tests/Conformance/drift-control.sh` drove both ports red naming the vector (Kotlin in CI run `33042568129`; Swift locally). **Partial** because of what the vectors do not assert — phase 2. |
| Kotlin compiles | **AUTOMATED** | First compiled 2026-08-26, run `33039508625`: `:android:assemble` BUILD SUCCESSFUL, 54 tasks. Before that it had never been handed to a compiler at all. |
| The CI gate is total | **NO — red, and partly nondeterministic** | Run `33044503283` (head `f769a6f`): `react-native`, `conformance-fixture`, `verify-policy` SUCCESS; **`ios` FAILURE**, **`android` FAILURE**. Re-read 2026-09-11, run `34556064209` (head `5ac68e3`): **`ios` FAILURE** on the same two Swift errors; `android` SUCCESS — which, per phase 1's exit rule, closes nothing. Phase 1; scheduled as tasklist `140`. |
| A skipped check can never read as a passing one | **AUTOMATED** | `.chief/verify.sh` reports three outcomes, and `.chief/tests/verify-skip-policy.sh` asserts both policies against the real script with an emptied `PATH`; the `verify-policy` job runs it on every push. |
| Background transfer while suspended (iOS + Android) | **NOT YET VERIFIED — physical device** | No device recording is checked in. Neither the host-side Swift tests nor the Android unit tests can produce one. |
| Process death → OS relaunch → resume → cancel | **NOT YET VERIFIED — physical device** | The *protocol and state* behaviour is automated (above, and `swift-wire.sh`'s SIGKILL is a genuine process death, not an OS-initiated one). An OS-initiated relaunch of a suspended app is not. |
| Real storage reclamation mid-transfer | **NOT YET VERIFIED — physical device** | Only the typed-failure path is automated (`StorageError.pressureRose`, partial remainder removed). Phase 5. |
| Android 15 `dataSync` six-hour budget exhaustion | **NOT YET VERIFIED — physical device** | The bounded-slice design is automated; a real OS timeout and successor worker are not. |
| Wi-Fi→cellular radio handoff | **NOT YET VERIFIED — physical device** | No checked-in test can cause one. |
| The React Native package binds to either native port | **NOT YET VERIFIED — nothing to verify** | `packages/react-native/src/NativeAmphora.ts` declares the codegen spec `AmphoraSpec`; grepping the Swift, Kotlin, ObjC and header sources for it returns **nothing**. There is no native implementation on either side, no podspec, and no Gradle module for the package. The control surface typechecks and builds; it is wired to no bytes. Phase 6. |
| Anyone has adopted this | **NO** | No host application, no published artifact, no tagged release. Phase 7. |
| Device evidence, overall | **0 of 40 cells** | Every one of the 10 × 4 cells in the environment matrix reads `NOT YET VERIFIED — physical device`. Phase 4. |

**The honest one-line summary:** the protocol layer, the state machines and the no-chunk-temp-files
commitment are now measured on both ports against a real server; **everything environmental — the
part this library exists for — is unverified**, and the gate that would keep the measured half from
regressing is itself red.

---

## 2. Phases

### Phase 1 — Make the gate total

CI runs, and it is red. It has been red on every run in its short life, which means the repository
currently has a gate that reports failure as its steady state — one step better than a gate that
cannot start, and one step short of useful.

Three distinct problems, all observed rather than inferred:

| Where | What | Observed |
|---|---|---|
| `ios/Sources/Amphora/Governor/NetworkGovernor.swift:23` | `reference to captured var 'self' in concurrently-executing code` | Run `33044503283`. Only the CI Swift surfaces it: the local toolchain does not, so `verify.sh` is green while the job is red. |
| `ios/Sources/Amphora/Transport/TUSKitTransport.swift:27` | stored property `session` of `Sendable`-conforming struct has non-`Sendable` type `BackgroundSessionManager` | Same run. The equivalent complaint against `NativeResumableTransport` was retired by the I6 seam's `BackgroundUploadStarter` wrapper — a narrow `@unchecked Sendable` claim over one call, **not** the redesign `BackgroundSessionManager` still needs. |
| `:android:kaptReleaseKotlin` | `AnnotationProcessingError: java.lang.IllegalStateException: Empty schema file` | **Nondeterministic.** The `android` job was SUCCESS at `89583f9` and FAILURE at `f769a6f`, and `git diff 89583f9 f769a6f` is *one JSON tasklist file* — no Kotlin, no Gradle, no Room entity changed. A gate that flips verdict on identical inputs does not gate anything. |

Because the `ios` job dies at its first step, everything after it — `swift run AmphoraPathTests`,
the Swift drift control — **never executes in CI**, and is run locally with the output recorded in
story notes instead. That is a stopgap, and it is the reason the Swift half of several rows above
says "local only".

**Scheduled:** [`140-ci-green-at-the-root`](tasks/chief/140-ci-green-at-the-root.json) takes all
three rows — `BackgroundSessionManager` gets a concurrency model at the current iOS 15 minimum (no
dependency on ADR-0002), and the Room schema directory moves to the Room Gradle plugin with the
exported schema committed. It cannot close this phase by itself: that needs a run on `main`, and
chief merges without pushing. Its last story names the operator's steps.
[`150-photos-assets-staged-before-upload`](tasks/chief/150-photos-assets-staged-before-upload.json)
follows it (phase 4, row 3).

**Closes when:** one run id shows every job green, the `ios` job is observed reaching and passing
its `swift run` and drift-control steps, and the Room kapt failure is either fixed at the root
(schema export configuration) or reproduced on demand — a green run after a red one on unchanged
input closes nothing.

### Phase 2 — Make the vectors binding

The fixture proves the two ports agree about *state*. It is documented, in
[Conformance vectors §3](docs/reference/conformance-vectors.md#3-what-the-vectors-do-not-cover), that
it proves considerably less than a reader would assume:

- **Ten `expect` keys are stated by the fixture and read by neither port** — `blockReason`,
  `errorClass`, `pauseReason`, `remoteTerminated`, `uploadUrl`, `noOp`, `persistBeforeTransfer`,
  `cleanupPending`, `fingerprint`/`sizeBytes`, `uploadExpiresAt`. A port that got every one of them
  wrong would still be green. `errorClass` drives retry policy; `remoteTerminated` is the flag that
  must survive a restart.
- **Two effects of eleven are asserted** (`terminateRemote`, `headBeforeResume`). Effect *ordering*
  is never checked at all.
- **Five of the nine invariants have no vector**: I2 (persist before you act — documented *by* a
  vector rather than verified by one), I3, I5, I8 (the durable lease), I9.

This is the phase where "the vectors exist" becomes "the vectors bind". Note the direction of the
one-way door: the counts (40 / 39 / 1 / 3) live in both ports' test code, not in the fixture, so
adding a vector deliberately requires touching both ports.

**Closes when:** every `expect` key the fixture states is read by both ports or deleted from it
(stating an unverified expectation is worse than stating nothing), effects and their ordering are
asserted, and each of I2, I3, I5, I8, I9 either has a vector or an entry in §3.3 saying which suite
owns it instead.

### Phase 3 — Repair and then *gate* the real-wire environment

The harness was repaired by `120` and it currently runs: `integration/tusd/run.sh` exits `0`
against a live daemon, with a three-valued exit contract observed on all four paths (live → `0`;
`DOCKER_HOST` pointed at a nonexistent socket → `77` SKIP; docker off `PATH` → `77`;
`AMPHORA_REQUIRE_DOCKER=1` with no daemon → `1`).

What remains is that it is only half a gate:

- **The Swift real-wire run is local-only.** CI's real wire lives in the `android` job; the `ios`
  job never reaches one because it fails at compile. So the strongest evidence this repository has
  for the Swift port — a genuine `SIGKILL` mid-transfer with a second process resuming — exists as
  one developer's terminal output, and nothing would notice if it stopped being true. This blocks
  on phase 1.
- **The pins can still rot.** The withdrawn `RELEASE.2024-06-13T19-44-55Z` MinIO tags are the
  precedent: a pin that guarantees reproducibility only until the registry withdraws it guarantees
  nothing. Both images are now digest-pinned with the release in a comment, and the separate
  `minio/mc` pin was deleted outright (mc ships inside the minio image) — one fewer tag that can be
  withdrawn. Nothing currently *detects* the next withdrawal except a red run.
- **The integration targets are opt-in.** `AmphoraTusdIntegration` and `TusdIntegrationTest` SKIP
  unless `TUSD_ENDPOINT` is set. Under the repository's own policy a skip is not a pass; in CI it
  is a failure. The android job sets it. Nothing else does.

**Closes when:** a single run id shows both ports crossing a real wire in CI, with the Swift
process-death run among them, and a scheduled or pre-flight check that fails loudly when a pinned
digest stops resolving.

### Phase 4 — Close the 40 device cells

Forty cells, ten rows × four interruption columns, every one of them
`NOT YET VERIFIED — physical device`. This is the largest single gap in the repository and it is
the one that cannot be closed by writing code.

The evidence contract already exists and does not need reinventing — per cell: device model, OS
build, app version, source kind, selected transport, start/end timestamps, interruption action,
stable job ID, server final offset, final state, plus the retained log or recording. Only that
cell's verdict changes, to `MANUAL-ON-DEVICE — <evidence name>`.

The rows are not equally valuable. In rough order of what they would retire:

1. **Android 15 / `dataSync` / local file** — the 6h/24h foreground-service budget is the constraint
   the whole bounded-worker design exists for, and it exists on no other platform.
2. **iOS 17+ / NativeResumableTransport / local file** — the native path most hosts would take.
3. **iOS / Photos asset** — the one source that genuinely cannot be seeked, and therefore the only
   place a staging copy and a storage reservation come into play at all. **Not runnable yet:** the
   Swift engine never calls `SourceResolver.stageIfRequired`, so a `ph://` job reaches the transport
   unstaged ([dead-code inventory §2.3](docs/reference/dead-code-inventory.md)). A device run of this
   row today would exercise that bug; tasklist `150` fixes it first.
4. **Android / non-seekable `content://`** — the same argument, other platform.
5. The remaining rows, which mostly re-verify a transport already covered by rows 1–4.

**Closes when:** all 40 read `MANUAL-ON-DEVICE`. Realistically it closes *usefully* at rows 1–4,
and the roadmap should say so rather than pretending a 40/40 sweep is imminent.

### Phase 5 — The storage governor under genuine pressure

This is the phase the repository exists for, and it is the least verified.

The origin story is a specific defect: uploads corrupted under AWS `TransferUtility` when iOS
reclaimed the app's cache directory mid-transfer. The claimed fix is structural rather than
defensive — stream byte ranges out of the source, write no chunk temp files, stage into Application
Support rather than the purgeable `Caches`, and reserve space via `StorageManager.allocateBytes` on
Android.

What is measured today: the typed-failure path (`StorageError.pressureRose`, partial remainder
removed) and the I6 disk-footprint numbers above. What is not measured: **the OS actually
reclaiming storage during a live transfer.** Every part of the claim that involves the operating
system's own behaviour is currently an argument from design.

The order matters and it is not negotiable: **reproduce the original bug first.** A run that shows
the new implementation surviving storage pressure proves nothing on its own unless the same
pressure, applied to a chunk-staging implementation, is shown to break it. Otherwise the conclusion
is "the device had enough space", not "the design retired the bug".

**Closes when:** one device recording shows a `Caches`-staging transfer corrupted or failed by real
OS reclamation, and a second, under the same applied pressure, shows the Amphora path completing
with the reservation and the Application Support staging observed. Both attached to the matrix's
`Storage reclaimed mid-transfer` column.

### Phase 6 — Host adoption via the React Native TurboModule

`@amphora/react-native@0.1.0` declares `codegenConfig.name: "AmphoraSpec"` and ships
`NativeAmphora.ts`, `types.ts` and `index.ts`. Nothing on either native side implements the spec —
no `RCTBridgeModule`/`ReactContextBaseJavaModule`, no podspec, no Gradle module for the package.
The package typechecks, builds, and passes its control-surface check; it is a control surface
attached to nothing.

The design constraint that shapes this phase: the TurboModule is a **control surface only**. No
transfer logic in JS, because JS does not run while the app is suspended — which is the entire
scenario this library is for. Every method is enqueue / pause / resume / cancel / query; progress
arrives coalesced at the native boundary (I9).

**Closes when:** a sample host application enqueues an upload from JS, is backgrounded, and is
observed completing the transfer — with the JS thread demonstrably not running for part of it. That
observation is a phase 4 device run wearing a different hat, so the two should be scheduled
together.

### Phase 7 — Publication

Deliberately last, and gated on the phases above rather than on effort. Publishing turns every
claim in the README into a claim someone else may rely on.

Preconditions, in order: phase 1 (a total gate), a resolved name (see open decisions — the current
one is explicitly a placeholder), the two outstanding ADRs recorded, [`CHANGELOG.md`](CHANGELOG.md)
carrying a real release entry rather than only its `[Unreleased]` section (the file itself now
exists), and at least rows 1–4 of phase 4 closed, because publishing a *background* uploader
whose background behaviour has never run on hardware would repeat tasklist `80`'s mistake at
registry scale.

Then: SemVer from `0.x` with the API surface explicitly unstable, `@amphora/react-native` to npm,
the Android library to Maven Central, the Swift package by git tag (SwiftPM needs no registry), and
a tagged release whose notes name the run id that was green.

**Closes when:** a consumer outside this repository can install a version, and the tag that
produced it is reachable from a green run.

---

## 3. Non-goals

These are not "not yet". They are commitments, and the first two are the reason this repository is
small enough to finish.

**No web transfer code.** Web is genuinely solved by `tus-js-client` and Uppy. Anything written here
for the browser would be a worse copy of a mature library, and it would double the surface that
every conformance vector, every device cell and every release has to cover. The web path uses
`tus-js-client` unmodified; it is not a dependency of this repository, it is a recommendation.

**No re-specification of the protocol.** The wire is
`draft-ietf-httpbis-resumable-upload`, spoken to tusd v2, with the interop version pinned. This
repository adopts that draft and builds clients for it. It does not fork it, extend it with private
headers, or vendor someone else's implementation of it. That decision is also why the licence
analysis concluded MIT's lack of a patent grant costs nothing here — there is no protocol invention
to grant rights over ([Licensing](docs/reference/licensing.md)).

**No chunk temp files. Ever.**

This is the one a future contributor is most likely to "optimise" away, so it is written down as a
commitment rather than left as an implementation detail. Writing each chunk to a temp file before
sending it is the obvious, comfortable, textbook implementation. It is also *exactly* the bug this
library was written to retire: it takes peak extra storage from ~0 to ~2× the file size, and on iOS
that staging traditionally lands in the purgeable `Caches` directory, which the OS may reclaim
mid-transfer — the `TransferUtility` corruption in phase 5.

So: byte ranges stream out of the source file. A copy is staged **only** when the source genuinely
cannot be seeked — `PHAsset`, some Android content providers — and only then does a storage
reservation come into play.

The commitment is enforced, not merely asserted. Invariant **I6** has three transport vectors in the
shared fixture that observe the filesystem during an attempt and fail if any file materialises; a
deliberate violation (`RangeRequestBody.writeTo` writing a temp file before streaming) was driven
red in `drift-control.sh` on both ports, naming `i6-01-fresh-transfer`. If you are here to make
chunked uploads faster by buffering to disk: the vectors will stop you, and this paragraph is why
they exist.

---

## 4. Open decisions

Listed because an undecided question that nobody has written down is indistinguishable from a
decided one.

**The name is a placeholder.** *Amphora* — the standardized vessel Mediterranean cargo shipped in —
was chosen as a working title and nothing depends on it. It is embedded in `@amphora/react-native`,
the Kotlin package `dev.amphora`, the Swift module `Amphora`, and `AmphoraSpec` in the codegen
config. Renaming is cheap **now** and expensive after phase 7 publishes any of those identifiers.
Whether the npm scope and the Maven group are actually available has not been checked. Deciding
before publication is close to free; deciding after is a deprecation cycle.

**Can device evidence ever be automated?** This is the load-bearing open question, because the
answer determines whether phase 4 is a one-off human effort repeated on every OS release, or
infrastructure. Real background suspension, OS-initiated process death, genuine storage reclamation
and radio handoff are precisely the behaviours a simulator does not reproduce — which is why the
matrix refuses simulator substitutes. Options not yet evaluated: a hosted device farm (Firebase
Test Lab, AWS Device Farm) and whether either can actually apply storage pressure or force a
`dataSync` budget exhaustion; a self-hosted runner with a tethered device; or accepting that these
cells are re-verified by hand each OS major and stating that openly in the matrix. **Until this is
answered, phase 4 has no schedule and the roadmap should not imply one.**

**The two ADRs listed in [`docs/README.md`](docs/README.md) are still unwritten** —
`0001-adopt-rufh-build-clients.md` (the build-vs-adopt analysis that motivated the repository) and
`0002-ios-deployment-target.md` (iOS 17 minimum versus carrying the pre-17 TUSKit remainder-staging
path). The second is not academic: dropping pre-17 would delete `TUSKitTransport`, which is where
one of the two `ios` compile errors in phase 1 lives, and would halve the iOS rows in the matrix.

**Who owns `BackgroundSessionManager`'s concurrency model?** Recorded in
[Continuous integration](docs/reference/continuous-integration.md) as owned by nobody. The
`@unchecked Sendable` wrapper introduced for the I6 seam is a narrow assertion about one call, not
a design. Phase 1 forces the answer.

**Repository visibility is load-bearing on billing.** The repository is public deliberately, because
this account's private-repository Actions are blocked outright by a payment failure. Making it
private would produce a workflow that cannot start — and a run that never starts reports no
failure. If that changes, say so out loud rather than letting the workflow file imply coverage.

---

## 5. What `100`–`120` actually measured — and what they did not

This roadmap was written after those three tasklists ran, deliberately, so it describes a measured
position rather than an intended one. What they established, at the granularity worth carrying
forward:

- **`100` (Android into CI)** established a remote and the first Kotlin compilation in this
  repository's history, and the compiler immediately found five real defects — a missing
  `room-ktx`, a `Call.await()` called at four sites and never written, a missing import, and a
  `ParcelFileDescriptor.seekTo()` that does not exist. It also made a skipped check unable to read
  as a passing one, with a counterfactual that runs in CI. **What it did not establish:** that the
  gate is green. It never has been.
- **`110` (Vectors on both ports)** made the fixture loadable from any working directory on both
  ports, ran the Kotlin half in CI for the first time, and — the part that matters — proved by
  committed negative control that the suite *notices* divergence rather than merely reporting
  agreement. **What it did not establish:** that the vectors assert enough to be binding; §3 of the
  conformance doc enumerates precisely what they let through, and phase 2 exists for it.
- **`120` (Real wire re-verified)** moved the first bytes this repository has ever moved, on both
  ports, across real interruptions, and measured the I6 footprint instead of reading it off the
  source. It also corrected tasklist `80`'s record, where two stories were marked passing while
  their own notes said the run never happened. **What it did not establish:** anything
  environmental. A `SIGKILL` is a real process death but it is not the OS suspending an app; a
  Docker container on a developer machine is not a phone on a cellular network.

**Two things are reported here as unverified rather than rounded up.** First, the **Swift real-wire
run is local-only** — it is genuine, and it is not gated, and if it regresses nothing will say so.
Second, on the machine these stories are written on, `.chief/verify.sh` reports **Gradle SKIPPED**
(no JDK on `PATH`), so every Android claim in this repository — including the Kotlin real-wire run —
is verified *only* by CI. When CI is red or flaky, as it is today, that is the whole of the Android
evidence chain.

---

## Related

- [Documentation index](docs/README.md) — every document in this repository.
- [Working in this repository](CLAUDE.md) — what a session here needs and cannot derive from the
  tree: the boundary, the no-chunk-temp-files commitment, and the two ways verification can be
  misread.
- [Changelog](CHANGELOG.md) — what changed and when, and why every entry is still `[Unreleased]`.
- [Environment verification matrix](docs/reference/environment-matrix.md) — the 40 device cells.
- [Environmental claim evidence](docs/reference/environment-evidence.md) — what automated evidence
  exists per environmental claim, and what it explicitly does not cover.
- [Conformance vectors](docs/reference/conformance-vectors.md) — what the fixture proves and what it
  lets through.
- [Continuous integration](docs/reference/continuous-integration.md) — the gate, and its known
  divergence from `verify.sh`.
- [The verification record](docs/reference/verification-record.md) — why nothing here is marked
  passing on work that did not run.
- [Licensing](docs/reference/licensing.md) — MIT, and the audit behind it.
