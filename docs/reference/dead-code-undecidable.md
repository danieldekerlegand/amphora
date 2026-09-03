# What the dead-code sweep could not decide

> **Status:** Live · **Updated:** 2026-09-03 · **Owner:** Daniel DeKerlegand

The third and last artifact of the dead-code sweep. The [inventory](dead-code-inventory.md) proposed
candidates, the [removal record](dead-code-removal.md) says what happened to them, and **this
document is the register of what the method could not answer at all.**

Nothing listed here was removed, and nothing here is a deferred removal. An honest *undecidable* is
a legitimate result: it says the search ran, returned zero references, and **zero references is not
the same fact as unreachable**. Every row below names the search, the reason its answer does not
settle the question, and the specific evidence that would settle it.

Read the last section first if you read only one — §3 is the honest statement of what a static
search over this tree cannot see, and it is the part with a track record behind it.

Everything was measured on `b11f66f`.

---

## 1. The register

Six classes. The inventory named four
([§4](dead-code-inventory.md#4-what-the-searches-cannot-decide)); working through the tree row by row
for this document found **two more that it missed**, and both occur here — §1.5 and §1.6.

### 1.1 Consumers outside this repository

The decisive class, and the one this portfolio has been bitten by before.

| Candidate | Search | Result |
|---|---|---|
| `AmphoraUploader.configure(store:…)` | `grep -rn --include='*.swift' -w configure ios/` | **1 line — its own declaration.** |
| `AmphoraUploader.handleBackgroundEvents(identifier:completionHandler:)` | same, `-w handleBackgroundEvents` | **1 line — its own declaration.** |
| `AmphoraUploader.shared` | `grep -rn --include='*.swift' AmphoraUploader ios/` | **2 lines — the type declaration and the singleton's own.** |
| `AmphoraUploader.get(context)` (Kotlin) | `grep -rn --include='*.kt' AmphoraUploader android/src` | **2 lines** — the memoisation inside its own companion, and `AmphoraGraph.kt:60` constructing the instance. No caller. |
| every export in `packages/react-native/src/index.ts` | `grep -n '^export ' packages/react-native/src/index.ts` + `tsc --noEmit` | **10 named exports plus `export * from './types'`, 0 in-repo importers.** `restoreUploads` is not called even by the package's own `index.ts`. |

**Why this is undecidable, stated as bluntly as it deserves:** apply S1/S3 honestly to the top of
this library and *the entire public API of both ports comes back dead*. `AmphoraUploader` is
referenced nowhere outside the file that declares it, on either platform. The searches that produced
the inventory, run against the one type the library exists to expose, would delete the library.

The consumers are real and they are in three places, none of them compiled:

- [`docs/guides/ios-host-integration.md`](../guides/ios-host-integration.md), which calls `configure`,
  `ready` and `handleBackgroundEvents` from an `AppDelegate` and describes **both** call sites as
  *"Not optional"*. That guide is the consumer, and a Markdown fence is not a reference.
- Host applications that do not exist yet. For a pre-1.0 library seeking adoption, "no consumer" and
  "no consumer **yet**" are opposite conclusions and no search run inside this tree can tell them
  apart.
- `.library(name: "Amphora")` in `ios/Package.swift` and the Android publication: a *product* is by
  definition a promise to code that is not here.

**What would decide it.** Nothing available in this repository. The evidence is an integrating host
app, or a public-API contract test that imports the package as a dependent would. Until one exists,
every symbol reachable from `AmphoraUploader` and from `index.ts` is undecidable, full stop.

### 1.2 Code generated at build time

| Candidate | Search | Result |
|---|---|---|
| the ten `EnumConverters` `@TypeConverter` methods | S4 | **0 call sites each.** kapt writes the calls into `UploadDatabase_Impl`. |
| `UploadDatabase.uploads()` | S4 | abstract, no body, no override in the tree — Room generates it. |
| all 12 `UploadDao` methods' *implementations* | S4 | `@Query`/`@Insert`/`@Update` bodies are generated; the interface is all this tree holds. |
| `AmphoraSpec` (RN TurboModule) | read `package.json` | named only in `codegenConfig.name`; React Native's codegen finds the spec by the **`Native*.ts` filename convention**, not by any import. |

`EnumConverters` is the row that makes the point of all three documents: ten functions, every one
reporting zero callers, every one mandatory — remove them and the module does not shrink, it stops
compiling. And it stops compiling **only in CI**, because there is no JDK here (§3.5).

**What would decide it.** A build, and only a build. `./gradlew :android:testDebugUnitTest` settles
the whole Room column — kapt either finds the converters or the compile fails. The TurboModule spec is
settled by React Native's codegen step inside a host app's Android or iOS build; this package has no
build of its own that runs it, and `npm run typecheck` does not (it type-checks the spec, which is
not the same as generating from it). Neither can run on this machine.

### 1.3 Framework and library dispatch

Everything in this class reports zero callers and is invoked by code this repository does not own.

| Candidate | Invoked by |
|---|---|
| `urlSessionDidFinishEvents(forBackgroundURLSession:)`, `urlSession(_:task:didReceiveInformationalResponse:)`, `…didSendBodyData…`, `…didCompleteWithError:` — `BackgroundSessionManager.swift:124-160` | `URLSession`, via `URLSessionDataDelegate` |
| `onAvailable` / `onCapabilitiesChanged` / `onLost` — `NetworkGovernor.kt:26-36` | `ConnectivityManager` |
| `onResponse` / `onFailure` — `CallAwait.kt:21-25` | OkHttp |
| `doWork()` — `UploadWorker.kt:32` | WorkManager |
| `contentType` / `contentLength` / `isOneShot` / `writeTo` — `TusTransport.kt:222-226` | OkHttp, when it writes `RangeRequestBody` to the wire |
| `close()` — `SourceResolver.kt:135` | `use { }` / try-with-resources |
| `UploadWorker(context, params)` | WorkManager's default `WorkerFactory`, **reflectively, from a class name** |

One of these deserves singling out. `urlSession(_:task:didReceiveInformationalResponse:)` is
`@available(iOS 17.0, *)` and fires only when a real server sends a real `104 Upload Resumption
Supported` to a real device. It is not merely uncalled in this tree — it is uncallable by anything
this repository can run, including its own test suite. It is also the sole insert point that
[inventory §2.4](dead-code-inventory.md#24-nativeresumeunavailable--plumbing-that-computes-nothing-guarding-a-documented-contract)'s
`nativeResumeUnavailable` chain is waiting on.

**What would decide it.** A device or simulator run with a real tusd behind it, i.e. exactly the
evidence [`ROADMAP.md` §1](../../ROADMAP.md) records as absent for all 40 device-matrix cells.

### 1.4 Reflection — the inventory's answer was true and misleading

Inventory §4.4 recorded: *"Searched for and not found: no `Class.forName`, no `NSClassFromString`,
no dynamic member lookup anywhere in the tree."*

That is accurate as a grep result and wrong as a conclusion. **This tree contains no reflection; it
feeds reflection that lives one frame away, in code it does not own.**

- `AmphoraGraph.kt:26-27` passes `UploadDatabase::class.java` to `Room.databaseBuilder`, which
  resolves `UploadDatabase_Impl` **by name** internally. A class-literal argument is a reflective
  lookup wearing a type.
- `OneTimeWorkRequestBuilder<UploadWorker>()` records the worker's class *name* into a persisted
  WorkManager row; the default factory instantiates it reflectively, possibly in a later process.
- `TurboModuleRegistry.getEnforcing<Spec>('Amphora')` resolves the native module by the **string**
  `'Amphora'`.

The correct statement of this limit is not "we searched for reflection and found none" but *"the
reflection that reaches this code is in libraries, so searching this tree for it can only ever
return zero."*

### 1.5 String-keyed decoding — a class the inventory did not name, with a proven near-miss

Symbols reached by their *spelling* in data, never by a reference. `grep -w` cannot see the edge,
and the compiler cannot either: rename one end and the build stays green.

**The proof, and it is a genuine near-miss.** `BlockReason.powerLow`:

```console
$ grep -rn --include='*.swift' -w powerLow ios/
ios/Sources/Amphora/Model/UploadJob.swift:121:    case powerLow          # its own declaration, and nothing else
$ grep -rn --include='*.kt' "POWER_LOW" android/
android/src/main/kotlin/dev/amphora/model/UploadJob.kt:90:    POWER_LOW,          # likewise
```

Zero references in **both** ports — by [inventory §1.3](dead-code-inventory.md#13-wiredialectrufh-kotlin--30-lines-nothing-constructs)'s
own reasoning the strongest dead-code signal this repository offers, since a symbol uncalled in both
independently written ports is exactly the shape that marked `WireDialect.Rufh`. It is live: exactly
one of the 40 vectors, `row-14-power-low`, carries the fixture string `"POWER_LOW"`, and both runners
decode it into the enum by raw value — `BlockReason(rawValue:)!` at `ConformanceTests.swift:165`,
`BlockReason.valueOf` at `ConformanceVectorsTest.kt:289`.

**This was run, not reasoned about.** Commenting the case out of the Swift enum and rebuilding:

```console
$ swift build --package-path ios
Build complete! (3.45s)                                    # compiles — nothing references it
$ swift run --package-path ios AmphoraPathTests
AmphoraPathTests/ConformanceTests.swift:165: Fatal error: Unexpectedly found nil while unwrapping an Optional value
```

The case was restored and the suite returns to `46 passed`. So the tree does defend itself here — but
by trapping on decode, not by failing an assertion, and only because someone wrote that one vector.
The `expect.blockReason` side of the row is asserted by neither runner. Nothing in the *search* would
have warned, and the reference count was as clean a zero as any row in the inventory.

The other string-keyed contracts, none of which a symbol search can traverse:

| Contract | Written as | Read as | Breaks how |
|---|---|---|---|
| `UploadState` raw values | `job.state.rawValue` → `state` column | SQL literals `'completed','failed','canceled'` (`SQLiteUploadStore.swift:53`, `:57`, `:61`, `:139`) and `'COMPLETED','FAILED','CANCELED'` (`UploadDao.kt:17`, `:21`, `:54`) | rename a case, compile clean, `unfinished()` silently returns everything |
| `UploadJob` `Codable` payload | JSON BLOB in `upload_jobs.payload` | property names | rename a property, orphan every persisted row |
| `URLSessionTask.taskDescription` | `= jobId` (`BackgroundSessionManager.swift:82`) | `task.taskDescription` in four delegate methods | see §1.6 |
| session identity `"dev.amphora.upload.background.v1"` | `URLSessionConfiguration.background(withIdentifier:)` | compared in `AmphoraUploader.swift:85` | change it and every in-flight upload is orphaned at the next launch |
| WorkManager `KEY_JOB_ID = "jobId"` | `workDataOf` | `inputData.getString` | survives process death as a string |
| unique work name `"amphora-job:$jobId"` | `enqueueUniqueWork` | `getWorkInfosByTag` | reconciler adoption silently adopts nothing |
| notification channel `"amphora-uploads"` | `NotificationChannel(...)` | `Notification.Builder(context, CHANNEL_ID)` | foreground service fails to start |
| RN module name `'Amphora'` / event name `'amphora'` | `getEnforcing('Amphora')`, `emitter.addListener('amphora', …)` | native registration | **unverifiable — the native side does not exist on either platform.** Note the casing differs between the two. |

**What would decide it.** For the enums, the existing vectors, where a vector exists — which is the
argument for the fixture, not for the search. For the rest, an integration test that round-trips the
value through the store or the framework. Several have neither today — including the row below.

#### A defect this class found: the Android adopt path queries a tag nothing writes

Reading the work-tag row rather than merely listing it turned up a live bug. Not fixed here — a
hygiene sweep reports, it does not repair — but recorded because it is what the class predicts.

| | |
|---|---|
| **Write** | `UploadWorker.kt:84` — `fun tag(jobId: String) = "amphora-job:$jobId"`, applied at `:92` and `:114`. Those two `addTag` calls are the **only** ones in the module. |
| **Read** | `Reconciler.kt:111` — `getWorkInfosByTag(WORK_TAG_PREFIX)`, where `WORK_TAG_PREFIX` is `"amphora-job"` (`:120`), with no colon and no job id. |
| **Mismatch** | `getWorkInfosByTag` matches a tag by **exact string equality**; WorkManager exposes no prefix query. No work request is ever tagged with the bare `"amphora-job"`, so the call returns an empty list and `liveWorkJobIds()` returns an empty set on every launch. |
| **Corroboration** | Line `:113` immediately strips `"$WORK_TAG_PREFIX:"` off each returned tag — the code is written as though the query *had* matched by prefix, which is the clearest evidence that the two ends were written against different assumptions. |
| **Consequence** | The Android launch reconciler can never adopt a running job. Every still-live upload looks orphaned and is driven down the recover path instead. This is the Kotlin half of what [`persistence-and-recovery.md`](persistence-and-recovery.md) specifies as the adopt/recover split. |
| **Coverage** | None. `grep -rn "liveWorkJobIds\|getWorkInfos" android/src/test` returns nothing, and the behaviour needs an instrumented device regardless. |

**Unverified locally, and doubly so:** there is no JDK on this machine (§3.5), and even with one this
is WorkManager runtime behaviour that a unit test does not reach. It is filed as a strong reading of
the code, not as an observed failure. The Swift port is unaffected — its adopt path matches on
`taskDescription` through `session.allTasks`, not on a tag.

### 1.6 Reachability only across a process boundary

The last class, and the one this library is *about*. The write and the read happen in **different
process lifetimes**, so a search sees two unrelated statements and the local suite sees neither edge.

- `taskDescription = jobId` is set before the app is terminated; it is read after iOS relaunches the
  process to replay background events. `UploadJob.swift:51-54` says exactly this — *"`taskDescription`
  survives as a plain string … this pair is what makes the adopt path in `Reconciler` possible."*
- The whole adopt path in `Reconciler.reconcile()` is reachable only on a launch that follows a
  termination-with-live-tasks.
- `systemCompletionHandler` is stored by `handleBackgroundEvents` (§1.1: zero in-repo callers) and
  invoked from `urlSessionDidFinishEvents` (§1.3: framework dispatch). **Both ends of this edge are
  already undecidable**, and the edge only exists after an OS-initiated relaunch.
- `resume_data`: written at `DefaultUploadEngine.swift:298`, and the read half is specified but
  unimplemented — see [removal record §2.1](dead-code-removal.md#21-loadresumedata--the-inventorys-evidence-for-this-row-was-wrong).

This class is worse than invisible to grep: it is invisible to the test suite too. It is the same
gap [`ROADMAP.md` §1](../../ROADMAP.md) reports as all 40 device-matrix cells reading
`NOT YET VERIFIED — physical device`, and [CLAUDE.md §8](../../CLAUDE.md) as *"everything
environmental — background suspension, OS-initiated relaunch, real storage reclamation, radio
handoff — is unverified"*. **A hygiene sweep must not delete the code paths that the project already
knows it cannot yet exercise.** Their being unexercised is a measured, documented property of the
project's current position, not evidence about the code.

---

## 2. What follows from the register

**Nothing in §1 was removed, and none of it is queued for removal.** A row leaves this document by
acquiring evidence, not by ageing.

It did, however, produce one thing a removal pass could not: **reading the undecidable rows instead
of counting them found a live defect** — the Android reconciler queries a WorkManager tag that
nothing writes (§1.5), so its adopt path can never fire. That is the third defect this tasklist has
surfaced without fixing, after the missing `stageIfRequired` call and the write-only `resume_data`
table. A sweep that only deletes would have found none of them.

The register also bounds the sweep's yield honestly. Of everything a static search flagged across
the whole tasklist, four things were removed
([removal record §1](dead-code-removal.md#1-what-was-removed)); three survived with reasons; eight
were classified load-bearing in advance; and the six classes above were never decidable to begin
with. That last group is much larger than the first — the public API of both ports, the entire RN
package, every Room-generated member, every framework callback. **The searches that can be run here
have an answer for a small minority of this tree**, and the useful output of a sweep in a repository
of specification-plus-skeletons is mostly a map of where its own instrument does not reach.

---

## 3. The limits of the method

Stated as a property of the instrument, so the next sweep starts here instead of re-deriving it.

1. **A reference count answers "is this named elsewhere in this tree", not "is this reachable".**
   Every class in §1 is a different way for those two to come apart. Where they disagree the refcount
   is the one that is wrong, and it fails *silently and confidently* — a clean zero looks identical
   whether the symbol is abandoned or load-bearing.

2. **The tree's edge is not the system's edge.** Consumers (§1.1), generators (§1.2), dispatchers
   (§1.3) and reflectors (§1.4) all live outside it. A grep is bounded by the repository; the
   program is not.

3. **Search sees symbols; this system also binds by string and by schema.** §1.5. The compiler is no
   help — both ends type-check independently — and `powerLow` is the standing proof that a symbol
   with zero references in *both* ports can still be live.

4. **Search sees one process. This library exists because there are several.** §1.6. Suspension,
   termination and OS-initiated relaunch are the scenario, and neither a static search nor the local
   suite spans them.

5. **This machine cannot compile half the tree.** There is no JDK on `PATH`, so `.chief/verify.sh`
   reports `Gradle build → SKIPPED`, which is **not** a pass ([CLAUDE.md §3](../../CLAUDE.md)). Every
   Kotlin row here — the whole of §1.2 in particular — is unverified locally by construction. The
   compiler is the only thing that can refute §1.2, and it does not run here.

6. **A quoted search is not an executed one, and they read identically.** The sharpest lesson of this
   tasklist, learned the expensive way: inventory §1.1 recorded a `grep` as returning nothing when
   running it returns four documentation lines, and acting on it would have deleted the only in-code
   trace of a documented iOS 17 capability. Struck through in place at
   [inventory §1.1](dead-code-inventory.md#11-resume_data-is-a-write-only-table--loadresumedata-has-no-caller)
   rather than rewritten, because the record that the method can fail this way is worth more than a
   tidy artifact. **Re-run every search before acting on it, including the ones in this document.**

7. **"Specified but unimplemented" and "dead" are indistinguishable to a search, and are opposites.**
   The discriminator is always a document, never a refcount — both of US-2's survivors were resolved
   by reading `docs/reference/`. When a zero-caller count is the entire case for deletion, grep the
   docs for the *mechanism* the symbol implements, not for its name.

---

## 4. Summary

| Class | Candidates | Decidable here? | What would decide it |
|---|---|---|---|
| §1.1 External consumers | the public API of both ports, all 10 RN exports | **No, by construction** | an integrating host app; a public-API contract test |
| §1.2 Generated code | 10 `@TypeConverter`s, `uploads()`, 12 DAO bodies, `AmphoraSpec` | No — needs a JDK / codegen | `./gradlew :android:testDebugUnitTest`; RN codegen |
| §1.3 Framework dispatch | 4 URLSession delegate methods, 3 network callbacks, 2 OkHttp callbacks, `doWork`, 4 `RangeRequestBody` members, `close()`, the `UploadWorker` constructor | No | device/simulator run against real tusd |
| §1.4 Reflection | `UploadDatabase::class.java`, the `UploadWorker` class name, `'Amphora'` | No — it is in the libraries, not here | reading the frameworks, not this tree |
| §1.5 String-keyed decoding | `powerLow` (**proven live with 0 refs**), 4 enum↔SQL contracts, 6 identity strings, **1 defect found** (the WorkManager adopt tag) | Partly — only where a vector already exists | round-trip tests; native RN implementation |
| §1.6 Cross-process reachability | `taskDescription`, the adopt path, `systemCompletionHandler`, `resume_data` | No — and the suite cannot see it either | the 40 device-matrix cells in [`ROADMAP.md`](../../ROADMAP.md) |

Every row: **left in place.**
