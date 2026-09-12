# Dead-code removal record

> **Status:** Live · **Updated:** 2026-09-03 · **Owner:** Daniel DeKerlegand

What the [dead-code inventory](dead-code-inventory.md) proposed, and what actually happened to each
row. Four changes went in, each as its own commit; **three §1 candidates survived**, and the reasons
they survived are the more valuable half of this document — they are what stops the next sweep
re-deriving the same files and reaching the same wrong conclusion.

The inventory is the *proposal*. This is the *disposition*. Where the two disagree, this document
is later and wins. What neither could decide — the public API of both ports among it — is registered
separately in [what the sweep could not decide](dead-code-undecidable.md).

---

## 1. What was removed

Four commits, one finding each, so any of them can be reverted alone. The gate was run after every
one; all four report `3 passed, 1 skipped, 0 failed` — see [§4](#4-what-the-local-gate-could-not-say)
for exactly what that skip means for the three Kotlin rows.

| # | Inventory row | Change | Commit | Verified by |
|---|---|---|---|---|
| 1 | [§3.1](dead-code-inventory.md#31-http-status--errorclass-twice-in-swift-verbatim) | `TransportError.errorClass`'s `.http` arm now calls `HTTPStatus.classify` instead of restating the six-arm table verbatim | `afabf05` | Swift build + 46 tests, locally |
| 2 | [§1.2](dead-code-inventory.md#12-uploaddaoinstate--a-room-query-with-no-caller-and-no-counterpart) | `UploadDao.inState` deleted, with the `UploadState` import it was the only user of | `ac91b10` | CI only |
| 3 | [§1.5](dead-code-inventory.md#15-uploadnotificationsensurechannel--a-version-guard-that-can-no-longer-be-false) | the `SDK_INT >= O` guard in `ensureChannel()` deleted; the body stays | `9edd129` | CI only |
| 4 | [§1.4](dead-code-inventory.md#14-androidxcorecore-ktx--a-dependency-nothing-imports) | `androidx.core:core-ktx` declaration deleted from `android/build.gradle.kts` | `6d16ac7` | CI only |

**No test was deleted, weakened or adjusted to keep any of these green.** That was the tripwire:
a removal that needs its test removed is a removal of something live. None of the four came near it —
the Swift suite runs the same 46 cases before and after, and no Kotlin test referenced any of the
three Kotlin rows.

Change 1 is the one worth reading. The two copies of the HTTP-status table were read on *different*
code paths — the background-session delegate and the foreground control plane — and nothing in
`Tests/Conformance/vectors.json` covers status classification, so editing one copy would have shipped
a build that retries `429` on `HEAD` and gives up on it mid-transfer with every vector still passing.
`HTTPStatus.classify` now carries a comment saying why it is the only copy.

## 2. What survived, and why

### 2.1 `loadResumeData` — the inventory's evidence for this row was wrong

**Inventory said:** [§1.1](dead-code-inventory.md#11-resume_data-is-a-write-only-table--loadresumedata-has-no-caller),
genuinely dead, corroborated by *"`grep -rn "resume_data\|resumeData\|ResumeData" docs/ Tests/ packages/ integration/`
returns **nothing**: no document … mentions it."*

**That grep does not return nothing.** Re-run it and it returns four documentation lines:

```console
$ grep -rn "resume_data\|resumeData\|ResumeData" docs/ Tests/ packages/ integration/
docs/reference/ios-background-transfer.md:65:… `cancelByProducingResumeData()` gives a resume blob for explicit pause; a failed
docs/reference/ios-background-transfer.md:66:upload can carry one in `URLError.uploadTaskResumeData`, which we persist **before** reporting the
docs/reference/platform-constraints.md:21:**iOS 17+ gives resumption natively.** `cancelByProducingResumeData()` /
docs/reference/platform-constraints.md:22:`uploadTask(withResumeData:)` implement the IETF resumable-upload draft, discover server support
```

Those lines are a specification, not a passing mention.
[`ios-background-transfer.md:65-66`](ios-background-transfer.md) states that the blob is persisted
*"**before** reporting the error, since its presence means 'resumable' rather than 'start over'"* —
persisted *in order to be read back*. [`platform-constraints.md:21-22`](platform-constraints.md)
names `uploadTask(withResumeData:)` as the iOS 17+ resumption mechanism, i.e. the consumer.

So this row belongs in the inventory's §2, not its §1. It is the same shape as
[§2.4 `nativeResumeUnavailable`](dead-code-inventory.md#24-nativeresumeunavailable--plumbing-that-computes-nothing-guarding-a-documented-contract):
**the write half is implemented, the read half is specified and unimplemented, and the callerless
function is the skeleton of the missing work rather than the residue of abandoned work.** Deleting
it would erase the only in-code trace of a documented iOS 17 capability.

The disk cost the inventory flagged is real and unchanged: `storeResumeData` fills `resume_data`
with blobs of hundreds of KB that nothing reads and nothing prunes. That is a **defect to fix by
implementing the reader**, not by deleting it, and it is out of scope for a hygiene sweep.

### 2.2 `WireDialect.Rufh` (Kotlin) — dead by search, alive by specification

**Inventory said:** [§1.3](dead-code-inventory.md#13-wiredialectrufh-kotlin--30-lines-nothing-constructs),
the only type in either port with a reference count of zero, and flagged there as needing a human
ruling rather than an agent's.

Left in place. [`wire-protocol.md:5-9`](wire-protocol.md) opens with *"Two dialects, one transport
interface"* and a column-per-dialect table naming `Rufh` (draft-11) beside `Tus10`, written to span
both ports; the Swift `RufhDialect` is live on the iOS 17+ branch (`UploadTransport.swift:64`).
Deleting the Kotlin half would make a documented two-dialect seam single-dialect on one platform and
turn a specification into a lie — which is the *opposite* of what this tasklist is for.

The right resolution is one of two things, and both are decisions rather than cleanups: implement
the Kotlin `Rufh` construction site, or amend `wire-protocol.md` to state that RUFH is iOS-only.
Recorded here so the next sweep stops at this paragraph instead of at the refcount.

### 2.3 `@RequiresApi(Build.VERSION_CODES.O)` ×3 — redundant, but true, and load-bearing

**Inventory said:** [§1.6](dead-code-inventory.md#16-requiresapibuildversion_codeso-3--always-satisfied),
*"weakest candidate in §1"*.

Left in place. The annotations constrain nothing at `minSdk = 26`, but they are accurate
documentation — `getAllocatableBytes` and `allocateBytes` really did arrive in API 26 — and they are
the sole reason `androidx.annotation` is on the classpath, so removing all three strands a second
dependency to make a third change of no behavioural consequence. The cost of the removal exceeds the
cost of the redundancy.

### 2.4 The other two duplications — real, and not worth their blast radius today

- **[§3.2](dead-code-inventory.md#32-the-two-swift-transports-duplicate-their-whole-control-plane-surface),
  the two Swift transports (~20 lines, nine overlapping windows).** Factoring these crosses exactly
  the seam invariant **I6**'s three transport vectors watch, and the difference between the two
  transports — whether a remainder is staged — *is* I6. Add to that a CI Swift toolchain stricter
  than the local one (`-Xswiftc -warnings-as-errors`, plus concurrency diagnostics the local
  compiler does not emit), and a refactor whose only benefit is line count is not worth being unable
  to verify locally. Deferred deliberately, not overlooked.
- **[§3.3](dead-code-inventory.md#33-offsetadvanced-twice-in-the-swift-state-machine), the
  `.offsetAdvanced` prefix.** A shared six-line prefix, not two implementations, and it is
  state-machine policy pinned by all 40 vectors. Lowest severity, highest risk. Left.

## 3. Everything in inventory §2 stayed, unexamined-for-deletion by design

The eight [deliberately-unexercised](dead-code-inventory.md#2-deliberately-unexercised--do-not-delete)
rows were not re-litigated here. The point of recording them was to make a second pass unnecessary,
and re-deriving them would defeat it. In particular `EnumConverters`' ten `@TypeConverter` methods
still report zero call sites each and the module still cannot compile without them.

One of them is worth restating because it names a live defect rather than a survivor:
[§2.3](dead-code-inventory.md#23-sourceresolverstageifrequired-swift--the-callee-is-fine-the-caller-is-missing) —
`DefaultUploadEngine.swift` never calls `sources.stageIfRequired(job)` while the Kotlin port calls
its twin at `DefaultUploadEngine.kt:217`, so a `ph://` job reaches the background session as
`URL(fileURLWithPath: "ph://…")`. **The caller is missing, not the callee.** Deleting the callee
would convert a missing call into a missing feature and destroy the evidence that the ports disagree.

> **Note, 2026-09-12, tasklist `150-photos-assets-staged-before-upload`.** The missing caller was
> supplied: `DefaultUploadEngine.startTransfer` now stages before it creates. The paragraph above
> is left as written — the decision it records (keep the callee, fix the caller elsewhere) is what
> made that a one-line change rather than a re-implementation. Kotlin turned out to carry a defect
> of its own at the same point, found only because the new shared rows run there too: a *seekable*
> `content://` was read as a refused reservation and blocked as `BLOCKED(STORAGE_LOW)` every time.
> Both are now guarded by `sourceStaging` and by a drift control per port
> ([conformance-vectors.md §4](conformance-vectors.md#4-the-negative-control)).

## 4. What the local gate could not say

`.chief/verify.sh` reported `3 passed, 1 skipped, 0 failed` after each of the four commits. Per
[CLAUDE.md §3](../../CLAUDE.md) that is **not** green: the skip is `Gradle build — no JDK on PATH`,
and it means every Kotlin claim here is unverified locally.

Three of the four removals are Kotlin (`inState`, the `SDK_INT` guard, `core-ktx`). **They rest
entirely on CI**, and this record should not be read as saying otherwise. What *was* verified on
this machine is change 1 and change 1 only: Swift build plus 46 passing cases (4 upload-path, 39
state-machine vectors, 3 I6 transport vectors), before and after, unchanged.
