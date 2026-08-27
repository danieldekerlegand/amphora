# Conformance vectors — what they prove, and what they do not

> **Status:** Draft · **Updated:** 2026-08-27 · **Owner:** Daniel DeKerlegand

`Tests/Conformance/vectors.json` is one file, read by both ports, and it exists for one reason: to
stop the Swift and Kotlin state machines drifting apart. This document records its **scope**, so
that scope is legible rather than assumed total. A suite whose coverage nobody has written down
gets read as covering everything, and the gaps then look like passing checks.

Where the vectors run, and the counterfactual that proves they bite, is in
[Continuous integration](continuous-integration.md#the-conformance-vectors-run-on-both-ports).

---

## 1. What is in the file

`schemaVersion` 2. Two sections, both required, both counted by both ports before either runs:

| Section | Rows | What a row is |
|---|---|---|
| `vectors` | 40 | `given` job state + `event` → `expect`. Fed to `UploadStateMachine.reduce`. |
| `transportInvariants.i6NoChunkTempFiles` | 3 | A file size and a resume offset → what the transport may do to disk. |

The counts (`40`, `1` non-reducing, `39` reduced, `3` I6) live in the two test files, not in the
fixture, so a fixture rewritten by a generator cannot rewrite its own expectations alongside it.
Adding a vector means touching both ports; that friction is the point.

---

## 2. What the vectors DO cover

**Every transition row asserts `state`.** All 40 rows carry an expected state, and both ports check
it. That is the bulk of the value: the §2 transition table, the §5 recovery algorithm, and the §6
cancel-an-orphan path are each exercised end to end through `reduce`.

**Four job fields beyond state**, where a row declares them:

| Field | Rows carrying it | Checked by both ports |
|---|---|---|
| `serverOffset` | 6 | yes |
| `attemptCount` | 6 | yes |
| `bytesTransferred` | 2 | yes |
| `terminateRemote` (as an emitted effect) | 2 | yes |

**One effect by name:** `HEAD_BEFORE_RESUME`, on `invariant-i1-resume-head`. That is the only
`requiredEffects` entry any row carries and the only effect either port looks for besides
`terminateRemote`.

**I6 — no chunk temp file outlives a transport attempt.** The three transport rows are the only
part of the fixture that is not a state transition. Each one writes a source file of a stated size
into a scratch directory, installs that directory as the process temp directory, runs the port's
own transport at the stated resume offset, and requires that **no file was created** and that the
bytes came straight out of the source at that offset. The observation is necessarily port-specific:

- **Swift** — `NativeResumableTransport.startTransfer` must hand the background session the
  *original* file (same path, same length on disk), with `sizeBytes - resumeFrom` as the expected
  byte count and no `stagedRemainderPath`.
- **Kotlin** — `RangeRequestBody` must stream exactly `source[resumeFrom, sizeBytes)` to its sink,
  declare that window as `Content-Length`, and leave the source file untouched.

This one earns its keep because a port that stages "just the remainder" satisfies all 40 transition
rows while taking peak extra storage from about zero to the size of the file — and reintroduces the
class of bug (the OS reclaiming a cache file mid-transfer) that the whole design exists to retire.

---

## 3. What the vectors do NOT cover

### 3.1 Fields the fixture states and neither port reads

These keys appear in `expect` and are **ignored by both ports**. They document intent; they do not
verify it. A port that got them wrong would still be green.

| Key | Rows | Consequence of the gap |
|---|---|---|
| `blockReason` | 5 | `BLOCKED` is asserted; *why* it blocked is not. |
| `errorClass` | 3 | `FAILED` is asserted; the classification that drives retry policy is not. |
| `pauseReason` | 2 | `PAUSED` is asserted; user-vs-system pause is not. |
| `remoteTerminated` | 2 | The cancel *effect* is checked; the flag that survives a restart is not. |
| `uploadUrl` | 2 | Whether the URL was stored at all is unchecked. |
| `noOp` | 2 | "Terminal states absorb" (I4) is checked only via the resulting state. |
| `persistBeforeTransfer` | 1 | **I2 is documented by a vector, not verified by one.** |
| `cleanupPending` | 1 | The deferred-termination flag is unchecked. |
| `fingerprint`, `sizeBytes` | 1 | `SourceResolved` payload propagation is unchecked. |
| `uploadExpiresAt` | 1 | Expiry parsing is unchecked here (the wire tests own it). |

### 3.2 Effects

Only `terminateRemote` and `headBeforeResume` are ever asserted. The other emitted effects —
`acquireLease`, `releaseLease`, `reserveSpace`, `releaseReservation`, `deleteStagedFile`,
`startTransfer`, `cancelTransfer`, `scheduleRetry`, `emit` — are produced by both ports and checked
by neither. Effect *ordering* is never checked.

### 3.3 Invariants without a vector

| Invariant | Status |
|---|---|
| I1 — server offset is the only authority | partial: one row asserts `HEAD_BEFORE_RESUME` is emitted |
| I2 — persist before you act | **not asserted** (see `persistBeforeTransfer` above) |
| I3 — no bytes in flight without a durable record | no vector |
| I4 — terminal states absorb | partial: resulting state only |
| I5 — reservation held across `PREPARING`→`FINALIZING` | no vector |
| I6 — no chunk temp file | covered, §2 above |
| I7 — offsets are monotonic | covered by `invariant-i7-offset-monotonic` |
| I8 — one runner per job, durable lease | no vector |
| I9 — progress coalesced at the boundary | no vector |

### 3.4 Whole layers that are out of scope

The vectors are a **pure-function** suite over `reduce`, plus three filesystem observations of the
transport. Nothing here opens a socket, a database, or an OS service. Not covered by this fixture,
by anything, or by another suite as noted:

- **Wire protocol** — header construction, dialect differences, relative `Location` resolution.
  Exercised against a real tusd by the integration targets (`AmphoraTusdIntegration`,
  `TusdIntegrationTest`), which are SKIPPED unless `TUSD_ENDPOINT` is set.
- **Persistence** — the SQLite/Room schema, migrations, the launch reconciler.
- **Concurrency** — the lease (I8), two runners racing, background-session task adoption after
  relaunch.
- **The React Native bridge** — event coalescing, the control surface.
- **Real devices and real interruptions** — see
  [environment-matrix.md](environment-matrix.md) and [environment-evidence.md](environment-evidence.md)
  for what is verified on hardware and what is still a gap.
- **What the OS does with the bytes.** The I6 rows prove *our* code creates no file during an
  attempt. They cannot prove `URLSession` or OkHttp never spools internally; that claim rests on
  the platform documentation quoted in [platform-constraints.md](platform-constraints.md).

---

## 4. The negative control

Green vectors prove the two ports **agree**. They do not prove the suite would **notice** if they
stopped agreeing — and a drift detector nobody has watched detect drift is indistinguishable from
one that cannot. `Tests/Conformance/drift-control.sh` is that counterfactual, committed as a script
rather than performed once and described in prose.

```sh
Tests/Conformance/drift-control.sh                # both ports, whatever toolchains are present
Tests/Conformance/drift-control.sh --port kotlin  # one port
```

It introduces a divergence into **one port at a time**, runs that port's vectors, and requires them
to go red *for the expected reason* — a non-zero exit alone is not accepted, because a file that no
longer compiles also exits non-zero:

| Control | Divergence | Must be caught by |
|---|---|---|
| swift / state-machine | `SourceMissing` → `BLOCKED(STORAGE_LOW)` instead of `FAILED(SOURCE_GONE)` | `row-04-source-missing` |
| swift / I6 | `startTransfer` writes a `.chunk` file beside the source | `i6-01-fresh-transfer` |
| kotlin / state-machine | the same `SourceMissing` divergence, in `UploadStateMachine.kt` | `row-04-source-missing` |
| kotlin / I6 | `RangeRequestBody.writeTo` writes a temp file before streaming | `i6-01-fresh-transfer` |

Each mutation is applied to the working tree, run, and restored from a byte-for-byte backup on
every exit path including interrupt; the script's last act is to prove all four target files are
identical to the copies it took at startup. It never commits and never stashes. A mutation whose
anchor text has gone missing is a **failure**, not a warning: a control that silently mutates
nothing would report that the vectors caught a divergence that was never introduced.

Both ports run it in CI — `--port swift` in the `ios` job, `--port kotlin` in the `android` job.
The `ios` job currently fails at its first step on three pre-existing Swift-concurrency errors
(recorded under [known divergence](continuous-integration.md#known-divergence-verifysh-is-not-identical-to-ci)), so the Swift half
does not yet execute on the runner; it is run locally instead, and the story notes record what it
printed.

---

## 5. Adding a vector

1. Add the row to `Tests/Conformance/vectors.json`. One file — never a per-platform copy;
   `Tests/Conformance/check-single-fixture.sh` fails the build on a second one.
2. Bump `EXPECTED_VECTOR_COUNT` (or `EXPECTED_I6_VECTOR_COUNT`) in **both**
   `ios/Tests/AmphoraTests/ConformanceTests.swift` and
   `android/src/test/kotlin/dev/amphora/ConformanceVectorsTest.kt`.
3. If the row asserts a field neither port reads today, teach both ports to read it — and move it
   out of §3.1 above. A row whose expectations nobody checks is documentation wearing a test's
   clothes.
4. Changing the fixture's *shape* means bumping `schemaVersion` in the file and in both ports.
