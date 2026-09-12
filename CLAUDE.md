# CLAUDE.md

> **Status:** Live · **Updated:** 2026-09-12 · **Owner:** Daniel DeKerlegand

Orientation for a session — human or agent — working in this repository. It covers the things that
are **not** derivable by reading the tree: the one design commitment that must survive contact with
a well-meaning optimiser, the two ways this repository's verification can lie to you if you read it
casually, and the boundary that decides whether a proposed change belongs here at all.

Everything here is load-bearing. Nothing here is a summary of the code — for that, read
[`docs/README.md`](docs/README.md), which indexes every document, and [`ROADMAP.md`](ROADMAP.md),
which states the measured position.

---

## 1. The boundary: adopt the protocol, build the clients

This repository does not invent a transfer protocol and does not implement one for every platform.
It **adopts** `draft-ietf-httpbis-resumable-upload` (tus 2.x lineage), spoken to **tusd v2** with
the S3 backend, and it builds the *clients* nobody else has built.

| Adopted, not built | Built here |
|---|---|
| The wire protocol (IETF draft, interop version pinned) | One state machine, specified in `docs/reference/state-machine.md`, ported to Swift and Kotlin |
| tusd v2 + S3 as the server | A durable job registry plus a launch reconciler |
| `tus-js-client` / Uppy for the **web** path, unmodified | A **storage governor** — the piece nothing off-the-shelf has |
| Native `URLSession` resumable upload on iOS 17+ | An Android background layer of bounded WorkManager slices |
| S3 multipart, as tusd's implementation detail | A React Native TurboModule that is a *control surface only* |

**A change is on the wrong side of the boundary if it:** adds web transfer code (web is solved —
this repository ships none), re-specifies or privately extends the protocol (no forks, no private
headers, no vendored implementation of someone else's client), or puts transfer logic in
JavaScript. That last one has a hard reason, not a stylistic one: **JS does not run while the app is
suspended**, and an app suspended mid-upload is the entire scenario this library exists for. Every
TurboModule method is enqueue / pause / resume / cancel / query; progress arrives coalesced at the
native boundary.

Full statement, with the reasoning: [`ROADMAP.md` §3 Non-goals](ROADMAP.md#3-non-goals).

## 2. No chunk temp files. Ever.

**If you are about to buffer a byte range to disk before sending it: stop.**

Writing each chunk to a temp file first is the obvious, comfortable, textbook implementation. It is
also *precisely* the bug this library was written to retire. It takes peak extra storage from ~0 to
~2× the file size, and on iOS that staging traditionally lands in the purgeable `Caches` directory —
which the OS may reclaim mid-transfer. That is how uploads corrupted under AWS `TransferUtility`,
and that defect is the origin story of this repository.

So: **byte ranges stream out of the source file.** A copy is staged *only* when the source genuinely
cannot be seeked (`PHAsset` on iOS, some Android content providers), and only then does a storage
reservation come into play.

This is enforced, not merely asserted. Invariant **I6** has three transport vectors in
`Tests/Conformance/vectors.json` that watch the filesystem during an attempt and fail if any file
materialises, and `Tests/Conformance/drift-control.sh` drives a deliberate violation red on **both**
ports naming `i6-01-fresh-transfer`. The vectors will stop you before review does.

Measured, not read off the source: peak extra disk during an 8 MiB transfer is **4 KiB** (Swift) and
**0 KiB** (Kotlin). A remainder-staging transport would have needed ≈2816 KiB. Those three numbers
have one home — [the tusd guide's storage section](docs/guides/tusd-integration.md#the-storage-claim-is-measured-not-asserted),
which states the sampling method behind them. This is a quotation; re-measure there, not here.

## 3. `SKIPPED` is not `PASS` — and it is the local default

`.chief/verify.sh` reports **three** outcomes, deliberately. The full policy, the counterfactual
that enforces it, and the two known ways `verify.sh` differs from CI live in
[Continuous integration § a skipped check is not a passing check](docs/reference/continuous-integration.md#a-skipped-check-is-not-a-passing-check);
what follows is the short form you need before your first run.

| Outcome | Meaning |
|---|---|
| `PASS` | The check ran and succeeded. |
| `FAIL` | The check ran and did not. |
| `SKIPPED` | The check **never ran**. The target is *unverified*. This is **not** a pass. |

The two environments disagree on purpose:

- **Local (default).** A developer machine legitimately lacks toolchains. A missing one is a fact
  about the machine, not a defect in the branch: report `SKIPPED`, name it in the summary, exit `0`.
- **CI (`CI=true`, set by GitHub Actions).** The workflow installs every toolchain first, so a check
  that skips *there* means an install step silently broke. **A skip is a failure** and the run goes
  red. `AMPHORA_VERIFY_STRICT=1` / `=0` overrides in either direction.

**What this means for you in practice.** On the machines this work is authored on there is **no JDK
on `PATH`**, so `Gradle build` always reports `SKIPPED`. A run that ends
`3 passed, 1 skipped, 0 failed` is **not** green — it means every Android claim in your change is
unverified locally and rests entirely on CI. Write that in your notes; do not write "green".

`.chief/tests/verify-skip-policy.sh` is the counterfactual — it runs the real `verify.sh` with an
emptied `PATH` and asserts the two verdicts actually differ. The `verify-policy` CI job runs it on
every push, so the distinction cannot be re-flattened without turning CI red.

The same rule governs the written record: **a story may not be marked passing on work its own notes
record as not having run.** This repository broke that rule once, at tasklist `80`, and what it cost
is written down in [The verification record](docs/reference/verification-record.md).

### Corollary: CI's Swift is stricter than yours

The `ios` job builds with `-Xswiftc -warnings-as-errors`, and so, since 2026-09-12, does
`verify.sh` — the flags now match. **The compilers do not.** Run `34675666580`'s `ios` job printed
`Apple Swift version 5.10` and `Xcode 15.4`; the machines this work is authored on run Swift 6.3.3
and Xcode 26.6, and the two disagree about concurrency diagnostics in **both** directions. That is
not hypothetical: the `ios` job was red for its entire life on two errors the local toolchain never
emitted, and a local `-strict-concurrency=complete` build emits one CI never mentions.

Both jobs are green as of run `34675666580` (branch `chief/140-ci-green-at-the-root`, both attempts),
so `verify.sh` and CI agree today. They agreed for the wrong reason before. A local pass is evidence;
it is not the gate — check `gh run list` ([`ROADMAP.md` phase 1](ROADMAP.md#phase-1--make-the-gate-total),
which is still open pending a run on `main`).

## 4. `swift test` reports "no tests found". The suite is fine.

`ios/Package.swift` declares the two test bundles as `.executableTarget`, not `.testTarget` — there
is no XCTest dependency anywhere in the package. So:

```console
$ swift test --package-path ios
error: no tests found; create a target in the 'Tests' directory     # exit 1
```

That is **not** an empty suite and **not** a broken package. The real command is:

```sh
swift run --package-path ios AmphoraPathTests     # 46 passed as of 2026-08-27
```

which is what `.chief/verify.sh` and the `ios` CI job both invoke: 4 upload-path cases, 39
state-machine vectors, 3 I6 transport vectors. The second executable target,
`AmphoraTusdIntegration`, is opt-in and SKIPs unless `TUSD_ENDPOINT` is set.

Do not conclude from `swift test` that there is nothing to run, and do not "fix" it by converting
the targets to `.testTarget` without reading why they are not.

## 5. Where things live

```
docs/reference/          the specification — behaviour lives here, not in platform code
docs/guides/             host-app integration
ios/Sources/Amphora/     Swift: state machine port, background session, two transports, governors
ios/Tests/               two .executableTarget bundles (see §4)
android/src/main/kotlin/ Kotlin: state machine, Room registry, governors, WorkManager slices
packages/react-native/   TurboModule spec and JS control surface
Tests/Conformance/       vectors.json — ONE file, read by both ports — plus the drift control
integration/tusd/        the real-wire harness: tusd v2 + MinIO via Docker Compose
.chief/                  the verify gate, its counterfactual test, and tasklist runtime state
```

## 6. Conventions worth matching

- **Docs are an evidence ledger, not prose.** State the verdict, name where it was read from, and
  never upgrade an unverified cell to make a table look finished. Every reference doc carries a
  `> **Status:** … · **Updated:** … · **Owner:** …` line.
- **A doc that drifted gets a `## Corrections` section, not a silent edit.** Dated, naming the
  tasklist, saying what the document *said*, what the tree says, and what was read to tell them
  apart — and saying what the pass did **not** check. A silently fixed doc teaches nobody why it
  drifted, and the next reader has no way to tell a claim that was verified from one that was
  merely never questioned. Nine files carry one as of 2026-09-03; `state-machine.md` is the
  worked example.
- **Index every new doc in [`docs/README.md`](docs/README.md).** That file states *"unlinked is
  unreachable"*; adding a document without indexing it is an incomplete change.
- **One `vectors.json`, no per-platform copy.** A second copy keeps both suites green while they
  describe two different state machines — the exact drift the fixture exists to catch, made
  invisible. `Tests/Conformance/check-single-fixture.sh` gates it from the git index.
- **The vector counts (40 / 39 / 1 / 3) live in both ports' test code, not in the fixture.** That is
  deliberate: a fixture cannot rewrite its own expectations, and adding a vector requires touching
  both ports. `BUILD SUCCESSFUL` on a task that ran zero vectors is a failure here.
- **Licence.** Root `LICENSE` (MIT) is authoritative; each *distributable manifest* carries
  `SPDX-License-Identifier`. No per-file headers — see
  [Licensing](docs/reference/licensing.md) for why, and for the dependency audit behind MIT.
- **Changes worth a reader's attention go in [`CHANGELOG.md`](CHANGELOG.md)** under `[Unreleased]`.
  Nothing is released yet; publication is gated on [`ROADMAP.md` phase 7](ROADMAP.md#phase-7--publication).

## 7. Commands

```sh
.chief/verify.sh                                   # the gate: PASS / FAIL / SKIPPED (§3)
CI=true .chief/verify.sh                           # strict — a skip is a failure
swift build --package-path ios                     # iOS build
swift run --package-path ios AmphoraPathTests      # the Swift suite (NOT `swift test`, §4)
./gradlew :android:testDebugUnitTest               # Kotlin vectors — needs a JDK; usually CI only
npm --prefix packages/react-native run typecheck   # RN control surface
Tests/Conformance/drift-control.sh --port swift    # the negative control
Tests/Conformance/check-single-fixture.sh          # the one-fixture invariant (reads the git index)
integration/tusd/run.sh                            # real wire; exits 77 = SKIP when Docker is absent
gh run list --limit 5                              # a run id and its conclusion ARE the claim
```

## 8. Before you claim something works

Read [`ROADMAP.md` §1](ROADMAP.md#1-where-this-actually-is--2026-08-27) first. It is a fourteen-row
table of what is measured and what is not, each cell naming its evidence. The short version: the
protocol layer, both state machines and the no-chunk-temp-files commitment are measured against a
real server; **everything environmental — background suspension, OS-initiated relaunch, real storage
reclamation, radio handoff — is unverified**, all 40 device-matrix cells read
`NOT YET VERIFIED — physical device`, and the CI gate is green twice on a tasklist branch and has
still never run green on `main`.

A simulator result is never substituted for a hardware one, here or anywhere else in this tree.

---

## Corrections

**2026-09-12, tasklist `140-ci-green-at-the-root`.** Two claims here had gone stale.

- **§3's corollary said the `ios` job is red today.** It is not: run `34675666580`, both attempts,
  all five jobs `success`. What was read to tell them apart is that run's job conclusions and its
  `ios` log, which printed `Amphora path tests: 46 passed` and
  `drift-control: 2 control(s) ran, 0 skipped, 0 failure(s)` — lines that had never appeared in CI
  before, because the job had never compiled. The corollary's *warning* is unchanged and still the
  point: the two toolchains are Swift 5.10 / Xcode 15.4 in CI against Swift 6.3.3 / Xcode 26.6
  locally, and they disagree in both directions.
- **§8 said "the CI gate is currently red."** It is green on a branch and has never been green on
  `main`, which is what it now says.

**What this pass did not check:** §§1, 2, 4, 5, 6 and 7 were not re-read against the tree. §3's
central rule is untouched — `Gradle build` still reports `SKIPPED` here for want of a JDK, and that
is still not a pass.
