# Dead-code inventory

> **Status:** Live · **Updated:** 2026-09-03 · **Owner:** Daniel DeKerlegand

The candidate list a human approves **before** anything is deleted. Every row names the search that
found it — the command and the scope it ran over — because a candidate list without its method is
unreviewable, and a deletion is irreversible in effect even when git remembers: nobody re-reads a
deleted file.

**Read the scope note first.** This repository is specification plus skeletons; nothing here moves
bytes in production. So "dead" cannot mean "unreachable at run time" — there is barely a run time.
It means **scaffolding that no longer matches the specification it was written against**, and a
skeleton is *not* dead merely because it is unused. That distinction is what §2 exists for.

**This document is the inventory as measured, before anything was deleted.** It is deliberately not
rewritten to match what happened next; the disposition of every row — four removed, three survived,
and one whose corroborating evidence here turned out to be **wrong** — lives in the
[dead-code removal record](dead-code-removal.md), which is later and wins where the two disagree.
Rows acted on carry a marker below.

---

## 0. The searches, and what they cover

Every claim below was produced by one of these. They ran from the repository root on the tree at
`7623788`, and they are reproducible: re-run one and you should get the row back.

| # | Search | Scope | What it answers |
|---|---|---|---|
| S1 | `grep -rhoE '(struct\|class\|enum\|protocol\|actor) [A-Z][A-Za-z0-9_]*' ios/Sources` → for each name, `grep -rn --include='*.swift' -w <name> ios/` minus its own declaration | all 54 Swift top-level types, both `Sources` and `Tests` | is a Swift type referenced anywhere in the package? |
| S2 | same shape over `grep -rhoE '(class\|object\|interface\|enum class\|data class\|sealed class\|sealed interface) [A-Z]...' android/src/main`, counted across `android/` | all 84 Kotlin declared types, `main` + `test` | is a Kotlin type referenced anywhere in the module? |
| S3 | `grep -rhoE 'func [a-z][A-Za-z0-9_]*' ios/Sources` → per name, `grep -rn --include='*.swift' -w <name> ios/ \| grep -v "func <name>"` | every Swift function, counted over `Sources` + `Tests` | does a Swift function have a call site? |
| S4 | same shape over `fun [a-z]...` in `android/src/main`, counted across `android/` | every Kotlin function | does a Kotlin function have a call site? |
| S5 | six-consecutive-normalised-source-line block hash, per language, comments/imports/blank stripped | `ios/Sources` + `ios/Tests`; `android/src` | two implementations of one behaviour |
| S6 | `grep -rn "TODO\|FIXME\|XXX\|HACK\|[Dd]eprecated"` and `grep -rn -E '^\s*//\s*(let\|var\|val\|func\|fun\|if\|for\|return\|import\|class\|struct)\b'` | all `*.swift *.kt *.ts *.js *.sh *.py` outside `node_modules` | commented-out blocks kept "just in case" |
| S7 | `grep -rn "^import <group>" --include='*.kt' android/src` per declared Gradle dependency; `ios/Package.swift` read for external packages | `android/build.gradle.kts` deps, `ios/Package.swift`, `packages/react-native/package.json` | dependencies nothing imports |
| S8 | `grep -rn "VERSION_CODES\|SDK_INT\|RequiresApi"` (Kotlin) and `grep -rn "#available\|@available"` (Swift), compared against `minSdk = 26` and `platforms: [.iOS(.v15), .macOS(.v14)]` | `android/src`, `ios/` | code behind a flag that can no longer be set |
| S9 | `grep -rn "<script>" . --include='*.sh' --include='*.yml' --include='*.md'` for each committed script, plus a read of `.github/workflows/ci.yml` and `.chief/verify.sh` | `integration/tusd/*.sh`, `Tests/Conformance/*`, `packages/react-native/scripts/*` | scripts nothing runs |

**What none of them can see** — sketched in §4 and treated in full in the
[undecidable register](dead-code-undecidable.md): consumers outside this repository, annotation-driven
code generation, framework dispatch, reflection, symbols bound by string rather than by reference,
and edges that only exist across a process boundary. **Five of the six occur here**, and §2 is mostly
made of them.

---

## 1. Genuinely dead — nothing reaches it, and no document says it is meant to be unreached

Six findings. None of them is large; the tree is disciplined (S6 found **zero** commented-out code
blocks across every source language, and exactly one `TODO`, at
`android/src/main/kotlin/dev/amphora/governor/StorageGovernor.kt:97`, which names future work rather
than hiding an abandoned path).

### 1.1 `resume_data` is a write-only table — `loadResumeData` has no caller

| | |
|---|---|
| **Where** | `ios/Sources/Amphora/Store/UploadStore.swift:34` (protocol), `Store/SQLiteUploadStore.swift:129` (implementation, plus the `CREATE TABLE resume_data` at `:32`) |
| **Search** | S3. `grep -rn --include='*.swift' -w loadResumeData ios/` returns **2 lines** — the declaration and the implementation. Zero call sites. |
| **Corroboration** | ~~`grep -rn "resume_data\|resumeData\|ResumeData" docs/ Tests/ packages/ integration/` returns **nothing**: no document, no vector, no host-facing API mentions it.~~ **This is wrong — see the correction below.** That grep returns four lines in `ios-background-transfer.md:65-66` and `platform-constraints.md:21-22`, which specify the blob's purpose and name its consumer, `uploadTask(withResumeData:)`. |
| **Why it matters** | The *write* half is live: `DefaultUploadEngine.swift:298` calls `store.storeResumeData` from the session delegate, so the table fills with iOS-17 resume blobs ("hundreds of KB", per the protocol's own doc comment) that nothing ever reads back. This is not merely unused code, it is unused code that consumes disk on a device — in a library whose reason for existing is that staged bytes on a full device corrupt uploads. |
| **Judgement** | ~~The reader half is dead.~~ **SUPERSEDED — NOT REMOVED.** The documentation above specifies the read-back this function is the unimplemented half of, which puts the row in §2 alongside §2.4, not here. The writer half remains a **live storage leak** — a defect to fix by implementing the reader, not by deleting it. Full reasoning: [removal record §2.1](dead-code-removal.md#21-loadresumedata--the-inventorys-evidence-for-this-row-was-wrong). |

### 1.2 `UploadDao.inState` — a Room query with no caller and no counterpart

**REMOVED** in `ac91b10`.

| | |
|---|---|
| **Where** | `android/src/main/kotlin/dev/amphora/store/UploadDao.kt:22` |
| **Search** | S4. `grep -rn --include='*.kt' -w inState android/` returns **1 line**, the declaration itself. |
| **Corroboration** | `grep -rn "inState" docs/ Tests/ packages/ integration/` returns nothing. Room generates the *implementation* of a `@Query`, never a caller, so codegen cannot be reaching it (contrast §2.1). And unlike §2.2 it has **no Swift counterpart**: `UploadStore.swift` declares no `inState`, so it is not one half of a deliberate cross-port registry API. |
| **Judgement** | Dead. The reconciler's working set is `unfinished()`; nothing needs a by-state query. |

### 1.3 `WireDialect.Rufh` (Kotlin) — 30 lines nothing constructs

**NOT REMOVED** — contested by `wire-protocol.md`; see [removal record §2.2](dead-code-removal.md#22-wiredialectrufh-kotlin--dead-by-search-alive-by-specification).

| | |
|---|---|
| **Where** | `android/src/main/kotlin/dev/amphora/transport/WireDialect.kt:62-91` |
| **Search** | S2, and it is the **only** type in either port with a reference count of zero. `grep -rn --include='*.kt' -w Rufh android/` returns **1 line**, the declaration. |
| **Corroboration** | Every construction site in the module passes tus 1.0: `TusTransport.kt:28` defaults `dialect = WireDialect.Tus10()`, `AmphoraGraph.kt:34` builds `TusTransport(OkHttpClient())` and takes that default, and all three `TusdIntegrationTest.kt` sites (`:63`, `:89`, `:113`) pass `WireDialect.Tus10()` explicitly. `grep -c "dialect\|Upload-Draft\|partial-upload" Tests/Conformance/vectors.json` → **0**: the shared fixture is state-machine-only and does not exercise dialects on either port. |
| **Against removal** | [`wire-protocol.md`](wire-protocol.md) documents `Rufh` as one of two named dialects in a table that spans both ports, and the Swift `RufhDialect` **is** live (`UploadTransport.swift:64`, the iOS 17+ branch). Deleting the Kotlin half makes a documented two-dialect seam single-dialect on one platform. |
| **Judgement** | Dead by search, **contested by the specification**. This is the row most likely to be a §2 finding in disguise, and it is the one a human should rule on rather than an agent. See §3. |

### 1.4 `androidx.core:core-ktx` — a dependency nothing imports

**REMOVED** in `6d16ac7`.

| | |
|---|---|
| **Where** | `android/build.gradle.kts:91` |
| **Search** | S7. `grep -rn "^import androidx.core" --include='*.kt' android/src` → **0 hits**. For contrast the same search returns 8 for `androidx.room`, 5 for `androidx.work`, 19 for `kotlinx.coroutines`, 13 for `okhttp3`, and 1 for `androidx.annotation` (§1.6). |
| **Caveat** | `core-ktx` is a transitive dependency of `work-runtime-ktx`, so removing the declaration changes the resolved classpath in no way that a compile can observe. That also means the removal is **unverifiable on the authoring machine**: there is no JDK on `PATH` here, `Gradle build` reports `SKIPPED`, and only CI can compile it. See §4. |
| **Judgement** | Dead declaration. Low value, non-zero risk, and the risk is entirely "CI is the only place this can be checked". |

### 1.5 `UploadNotifications.ensureChannel` — a version guard that can no longer be false

**REMOVED** in `9edd129`.

| | |
|---|---|
| **Where** | `android/src/main/kotlin/dev/amphora/work/UploadNotifications.kt:31` — `if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)` |
| **Search** | S8, cross-referenced against `android/build.gradle.kts:14`, `minSdk = 26`. `VERSION_CODES.O` **is** API 26, so the condition is true on every device the library can be installed on and the implicit `else` is unreachable. |
| **Contrast** | The sibling guard at `:23` (`>= VERSION_CODES.Q`, API 29) is live and must stay — 26 through 28 take the two-argument `ForegroundInfo`. |
| **Judgement** | Dead branch. The condition, not the body. |

### 1.6 `@RequiresApi(Build.VERSION_CODES.O)` ×3 — always satisfied

**NOT REMOVED** — the annotations are true, and they are what keeps `androidx.annotation` on the classpath; see [removal record §2.3](dead-code-removal.md#23-requiresapibuildversion_codeso-3--redundant-but-true-and-load-bearing).

| | |
|---|---|
| **Where** | `android/src/main/kotlin/dev/amphora/governor/StorageGovernor.kt:49`, `:59`, `:100` |
| **Search** | S8, same `minSdk = 26` comparison as §1.5. An annotation asserting API ≥ 26 on a module whose floor is API 26 constrains nothing and lint cannot act on it. |
| **Against removal** | It is *true* documentation — `getAllocatableBytes` and `allocateBytes` genuinely arrived in API 26 — and it is the sole reason `androidx.annotation` (`build.gradle.kts:90`) is on the classpath, so removing all three strands a second dependency. |
| **Judgement** | Redundant rather than wrong. Weakest candidate in §1; listed for completeness so the next sweep does not re-derive it. |

---

## 2. Deliberately unexercised — do not delete

Each of these fails a static search and is nonetheless load-bearing. Deleting any one removes a
stated contract, and the search that "found" it is answering a question it cannot answer.

### 2.1 `EnumConverters` — reached only by annotation-driven code generation

`android/src/main/kotlin/dev/amphora/store/EnumConverters.kt` declares ten functions
(`uploadStateToString`, `stringToUploadState`, `blockReasonToString`, `pauseReasonToString`,
`errorClassToString`, `sourceKindToString`, and their inverses). **S4 reports a call site count of
zero for every one of them.** They are `@TypeConverter`s; Room's kapt processor emits the calls into
generated `UploadDatabase_Impl`. Removing them does not shrink the module, it makes it fail to
compile — and only in CI, since no JDK exists here.

*This is the row that makes the point of the whole document.* Ten functions, every one apparently
callerless, every one mandatory.

### 2.2 `renewLease` and `pruneCompleted` — a symmetric, specified registry API

Zero call sites in **both** ports (`UploadStore.swift:28`/`:37`, `SQLiteUploadStore.swift:117`/`:138`,
`UploadDao.kt:52`/`:59`). Not dead:

- **Symmetric across two independently written ports.** A skeleton that both ports grew
  independently is a specified surface, not an accident. Contrast §1.2, whose Kotlin-only asymmetry
  is exactly what marks it as genuinely stray.
- `pruneCompleted` carries a stated retention decision, in identical words in both files:
  *"Completed rows are retained, not deleted — 'did it upload last Tuesday?' is a real question."*
  Deleting the method deletes the only statement of the policy.
- `renewLease` is half of state-machine invariant **I8**. `tryAcquireLease` and `breakStaleLeases`
  are live (`UploadWorker.kt:38`, `Reconciler`); a long slice that cannot extend its own lease is a
  gap in I8's implementation, not a surplus method.

### 2.3 `SourceResolver.stageIfRequired` (Swift) — the callee is fine, the caller is missing

`ios/Sources/Amphora/Core/SourceResolver.swift:62`. S3 reports **zero** call sites. But the Kotlin
port calls its twin (`DefaultUploadEngine.kt:217` → `SourceResolver.kt:84`), and the Swift function
is the only implementation of the `ph://` export path that
[`persistence-and-recovery.md` §3](persistence-and-recovery.md) and
[CLAUDE.md §2](../../CLAUDE.md) both describe — the one case where a copy is legitimately staged.

`DefaultUploadEngine.swift:178-253` never calls it, so a `PHAsset` job reaches
`URL(fileURLWithPath: "ph://...")`. **That is a port-drift defect in the caller, and this inventory
is not the place to fix it.** Deleting the callee would convert a missing call into a missing
feature and erase the evidence that the two ports disagree.

### 2.4 `nativeResumeUnavailable` — plumbing that computes nothing, guarding a documented contract

Five files carry the `noteNativeResumeSupported` chain: `BackgroundSessionManager.swift:144` →
`UploadEngine.swift:35` (protocol) → `AmphoraUploader.swift:156` (proxy) →
`DefaultUploadEngine.swift:301` → `markNativeResumeSupported` at `:305`, which does exactly one
thing: `nativeResumeUnavailable.remove(jobId)`.

The set at `DefaultUploadEngine.swift:28` is **never inserted into and never read**. The chain is a
no-op end to end, and it looks maximally alive — a protocol method with a test stub
(`UploadPathTests.swift:171`) and a thread-safe proxy.

It is not dead, because [`wire-protocol.md:57-63`](wire-protocol.md) specifies the behaviour it is
the skeleton of: *"no `104` by first body bytes → the job is marked `nativeResumeUnavailable`, and
the engine drives its own `PATCH`-based resume instead of trusting the system"*, and calls it *"a
metric worth alerting on"*. The insert side is unimplemented. Removing the plumbing deletes the only
in-code trace of the silent-degradation hazard the wire doc is most emphatic about.

### 2.5 `consumer-rules.pro` — empty, and says so

`android/consumer-rules.pro` contains one comment line: *"Consumer rules are intentionally empty
until the public API has a shrinker contract."* Referenced from `build.gradle.kts:16`. The textbook
"deliberately unexercised and says so".

### 2.6 The `packages/react-native` control surface — an external-consumer API with no consumer yet

Every symbol in `src/index.ts`, `src/NativeAmphora.ts` and `src/types.ts` is exported and unused
inside this repository, because the consumer is a host app. `AmphoraSpec` additionally has **no
native implementation on either platform** — recorded already in `README.md`. Unimplemented and
unused-here is the expected state of a published control surface; none of it is a deletion
candidate, and `scripts/check-control-surface.js` (run by CI, `ci.yml:130`) exists specifically to
keep transfer logic *out* of it.

### 2.7 The integration harness — not in CI, and the docs say why

`integration/tusd/run.sh`, `resume.sh`, `swift-wire.sh`, `lib.sh` and the
`AmphoraTusdIntegration` target appear in no workflow (S9). All are documented and deliberate:
[`tusd-integration.md:128`](../guides/tusd-integration.md) states the reason — *"GitHub's `macos-*`
runners have no Docker daemon, and the Swift toolchain is only on the macOS runner. Run them
locally."* — and `swift-wire.sh` is cited as evidence in `ROADMAP.md:25` and `CHANGELOG.md:47`.
`Tests/Conformance/apply-mutation.py` is invoked by `drift-control.sh:39`, which CI runs twice
(`ci.yml:35`, `:92`).

### 2.8 `TUSKitTransport` — a whole file whose deletion is a *product* decision

`ios/Sources/Amphora/Transport/TUSKitTransport.swift` is reachable only through
`TransportSelector.select`'s `else` branch (`UploadTransport.swift:70`), i.e. only below iOS 17. It
is the one place in the tree that stages a remainder to disk, so it reads like the natural target of
a "no chunk temp files" cleanup. It is not: its own header states the cost honestly, and *"setting
the deployment target to iOS 17 removes this file and the entire failure mode with it"* is an open
decision with an ADR slot already reserved (`docs/README.md`, `0002-ios-deployment-target.md`).
Raising `platforms: [.iOS(.v15)]` is a product decision, not a hygiene sweep's.

---

## 3. Duplicated implementations

First-class findings, ranked by what drift would cost. **These are the rows that matter most**: an
unused function is inert, whereas two implementations of one behaviour actively rot, because the
next change edits one of them.

The three below are all *intra-port* duplication. The Swift↔Kotlin state machines are **not** listed:
two ports of one specification is this repository's design, and `Tests/Conformance/vectors.json` plus
`drift-control.sh` exist precisely to keep them honest.

### 3.1 HTTP-status → `ErrorClass`, twice in Swift, verbatim

**RESOLVED** in `afabf05` — `TransportError.errorClass` now defers to `HTTPStatus.classify`.

| | |
|---|---|
| **Where** | `ios/Sources/Amphora/Session/BackgroundSessionManager.swift:212-223` (`HTTPStatus.classify`) and `ios/Sources/Amphora/Transport/ControlPlaneClient.swift:124-132` (`TransportError.errorClass`, the `.http(code)` arm) |
| **Search** | S5 flagged the shared tail (`case 400, 413: return .fatal` / `case 429, 500...599: return .transient` / `default: return .fatal`); reading both confirms the **entire** six-arm table is identical — `401,403→auth`, `409,460→protocolError`, `412→protocolVersion`, `400,413→fatal`, `429,5xx→transient`, `default→fatal`. |
| **Why it is the worst one** | This table is the retry policy. The two copies are read on different paths — the background-session delegate uses one, the foreground control plane the other — so a change applied to one copy produces a build that retries `429` on `HEAD` and gives up on it during transfer, with every test still green. Nothing in the fixture covers status classification. |
| **Note** | Kotlin's equivalent (`TusTransport.kt:170-175`) is a *third* spelling but a legitimate one: it omits `409/460` because it models offset conflict as a typed exception (`OffsetConflict`) instead. That is a port difference, not intra-port duplication. |

### 3.2 The two Swift transports duplicate their whole control-plane surface

| | |
|---|---|
| **Where** | `NativeResumableTransport.swift:68-102` vs `TUSKitTransport.swift:47-95` |
| **Search** | S5, which returned **nine overlapping six-line windows** across this pair — by far the densest cluster in the tree. |
| **What is duplicated** | (a) `create`, `head` and `terminate` are byte-identical one-line delegations to `control` in both files; (b) the seven-line PATCH request construction — `URLRequest`, `httpMethod = "PATCH"`, `appendContentType`, `dialect.decorate`, the `appendHeaders(offset:isFinalSlice: true)` loop — is identical. |
| **What is genuinely different** | Only the body URL: `NativeResumableTransport` always hands over the original file, `TUSKitTransport` may stage a remainder. That difference **is** the reason two transports exist (`UploadTransport.swift:3-4`), and it is invariant **I6**. |
| **Judgement** | Real, ~20 lines, and safe in principle to factor. But the seam it would cross is the one I6's three transport vectors watch, and CI's Swift is stricter than the local toolchain (`-Xswiftc -warnings-as-errors`, plus concurrency diagnostics the local compiler does not emit — see [CLAUDE.md §3](../../CLAUDE.md)). A refactor here is not free. |

### 3.3 `.offsetAdvanced`, twice in the Swift state machine

| | |
|---|---|
| **Where** | `ios/Sources/Amphora/Core/UploadStateMachine.swift:86-92` (`.uploading`) and `:156-169` (`.recovering`) |
| **Search** | S5, two overlapping windows: the I7 guard `guard offset >= job.serverOffset else { return expire(job, now) }` plus the four field writes (`serverOffset`, `bytesTransferred`, `serverOffsetAt`, `updatedAt`). |
| **Extent** | A shared six-line **prefix**, not two full implementations — `.recovering` then diverges to pick a next state. The Kotlin port expresses the same pair differently (`UploadStateMachine.kt:82-89` and `:142-149`) and S5 found **no** duplicate block anywhere in Kotlin. |
| **Judgement** | Lowest severity of the three, and the highest-risk to touch: it is state-machine policy, pinned by all 40 vectors. Recorded so the next sweep does not mistake it for something new. |

---

## 4. What the searches cannot decide

**Superseded and extended by the [undecidable register](dead-code-undecidable.md), which is the
full treatment.** Two things about this section did not survive being worked through row by row:
the list of four classes is **incomplete** — string-keyed decoding and cross-process reachability
both occur here and are missing below — and item 4's reflection finding is true as a grep result but
misleading as a conclusion. Both are corrected in place below rather than rewritten.

Stated here as a limit of the method, not as a disclaimer. A static search over this tree is blind to
~~four~~ **six** things, and ~~three~~ **five** of them occur:

1. **Consumers outside this repository.** The decisive one, and the one this portfolio has already
   been bitten by. `packages/react-native/src/*` and the `public` surface of `AmphoraUploader` on
   both platforms exist *to be* called from host applications that are not in this tree. No search
   run here can distinguish "no consumer" from "no consumer **yet**", and for a pre-1.0 library
   intended for adoption those are opposite conclusions.
2. **Annotation-driven code generation.** §2.1: ten `@TypeConverter` methods that every call-site
   count reports as zero and that the module cannot compile without. kapt runs only where a JDK
   exists, which is not here.
3. **Framework and library dispatch.** `urlSession(_:task:didCompleteWithError:)` and its siblings
   (`BackgroundSessionManager`) are invoked by `URLSession`; `onAvailable` / `onLost` /
   `onCapabilitiesChanged` (`NetworkGovernor.kt`) by `ConnectivityManager`; `onResponse` /
   `onFailure` (`CallAwait.kt`) by OkHttp; `doWork` (`UploadWorker.kt`) by WorkManager. S3 and S4
   report **zero** call sites for all of them. Every one is mandatory.
4. **Reflection.** ~~Searched for and not found: no `Class.forName`, no `NSClassFromString`, no
   dynamic member lookup anywhere in the tree.~~ **True, and misleading.** The tree contains no
   reflection because the reflection that reaches this code lives in the libraries: `Room
   .databaseBuilder(…, UploadDatabase::class.java, …)` resolves `UploadDatabase_Impl` by name,
   WorkManager instantiates `UploadWorker` from a persisted class name, and
   `TurboModuleRegistry.getEnforcing<Spec>('Amphora')` resolves by string. Searching *this* tree for
   reflection can only ever return zero. See
   [undecidable §1.4](dead-code-undecidable.md#14-reflection--the-inventorys-answer-was-true-and-misleading).

5. **Symbols bound by string rather than by reference** — *missing from this list as first written*.
   `BlockReason.powerLow` has **zero** references in **both** ports and is live: one conformance
   vector reaches it through `rawValue`/`valueOf`. Enum names are also spelled into SQL literals in
   both stores. See
   [undecidable §1.5](dead-code-undecidable.md#15-string-keyed-decoding--a-class-the-inventory-did-not-name-with-a-proven-near-miss).

6. **Edges that only exist across a process boundary** — *also missing as first written*, and the
   sharpest omission, because it is the scenario this library exists for. `taskDescription` is
   written before termination and read after an OS-initiated relaunch; the `Reconciler` adopt path
   is reachable on no other launch. Invisible to search *and* to the local suite. See
   [undecidable §1.6](dead-code-undecidable.md#16-reachability-only-across-a-process-boundary).

There is a fifth limit specific to this machine, and it is the sharpest constraint on story US-2.
**There is no JDK on `PATH` here**, so `.chief/verify.sh` reports `Gradle build → SKIPPED` — which is
*not* a pass ([CLAUDE.md §3](../../CLAUDE.md)). Four of the six §1 findings (§1.2, §1.3, §1.4, §1.5)
and one §2 finding are Kotlin. Any removal among them is unverifiable locally by construction and
rests entirely on CI, and this document should not be read as saying otherwise.

---

## 5. Summary

| Class | Count | Disposition |
|---|---|---|
| Genuinely dead (§1) | 6 as measured, **3 on review** | 3 removed (§1.2, §1.4, §1.5). §1.1 was misclassified here and stays; §1.3 and §1.6 stay with reasons. See the [removal record](dead-code-removal.md). |
| Deliberately unexercised (§2) | 8 | **Do not delete.** Recorded so the next sweep stops here rather than re-deriving them. |
| Duplicated implementations (§3) | 3 | §3.1 resolved — it was the only one whose drift was both silent and behavioural. §3.2 and §3.3 deferred, with reasons. |
| Undecidable (§4) | 4 classes as measured, **6 on review** | Left in place by construction. Registered candidate-by-candidate, with the two classes this section missed, in the [undecidable register](dead-code-undecidable.md). |

Two things the sweep looked for and did not find, worth stating so nobody looks again: **zero**
commented-out code blocks in any source language (S6), and **zero** unused imports in the Swift
package (S7). One `TODO`, at `StorageGovernor.kt:97`, describing future work rather than concealing
abandoned work.
