# Upload state machine

> **Status:** Draft · **Updated:** 2026-09-03 · **Owner:** Daniel DeKerlegand

The transfer core is one state machine, specified here once and implemented three times
(Swift, Kotlin, and — for the web — as a thin adapter over `tus-js-client`). Platform code
supplies *events*; it does not decide *transitions*. Anything that reads like policy
("should we resume on cellular?") belongs here, not in a `URLSession` delegate.

A **job** is one source file → one destination. Jobs are independent; batches are a grouping
label (`groupId`), never a shared state.

---

## 1. States

Non-terminal states persist across process death. Every state below is written to durable
storage before the transition is observable to callers.

| State | Meaning | Bytes in flight? |
|---|---|---|
| `PENDING` | Enqueued and persisted; scheduler has not picked it up | no |
| `PREPARING` | Resolving the source (PHAsset export, `content://` copy), fingerprinting, reserving storage | no |
| `CREATING` | Creating the remote upload resource; the returned URL is being persisted | no |
| `UPLOADING` | Transferring | **yes** |
| `PAUSED` | Halted by explicit user intent — **sticky**, never auto-resumes | no |
| `BLOCKED` | Halted by an environmental gate — **auto-resumes when the gate clears** | no |
| `RETRY_WAIT` | Backoff between attempts after a retryable error; has a `nextAttemptAt` deadline | no |
| `FINALIZING` | All bytes sent; awaiting the server's completion acknowledgement | no |
| `RECOVERING` | Entered *only* by the launch reconciler; reconciling local record against server truth | no |
| `COMPLETED` | Terminal, success | no |
| `FAILED` | Terminal, unrecoverable for this job | no |
| `CANCELED` | Terminal, caller-initiated; remote resource terminated if reachable | no |
| `EXPIRED` | Remote upload resource is gone (404/410, or `Upload-Expires` elapsed) | no |

### Why `PAUSED`, `BLOCKED`, and `RETRY_WAIT` are three states, not one

They differ in **who is allowed to restart them**, which is exactly the distinction that gets
lost when they are collapsed into a single `paused` flag with a reason string:

- `PAUSED` survives restart and resumes **only** on an explicit `Resume` command.
- `BLOCKED` resumes automatically the instant its gate reports clear. It must never require
  user action, and it must never be surfaced as an error.
- `RETRY_WAIT` resumes automatically at a **deadline**, and its attempt counter feeds the
  transition to `FAILED`.

`BLOCKED` carries a `blockReason`. Four are shared; two are platform-specific, and neither port
declares the other's:

| `blockReason` | Kotlin | Swift |
|---|---|---|
| `NETWORK_UNAVAILABLE` | yes | yes |
| `NETWORK_DISALLOWED` (metered network, policy forbids) | yes | yes |
| `STORAGE_LOW` | yes | yes |
| `POWER_LOW` | yes | yes |
| `CONCURRENCY_LIMIT` | yes | yes |
| `FGS_QUOTA_EXHAUSTED` — Android only, see `platform-constraints.md` §2 | yes | — |
| `REMAINDER_STAGING_DENIED` — iOS only, pre-17 background resume needed a staged remainder and the reservation was refused; see `ios-background-transfer.md` §4 | — | yes |

Read from `dev.amphora.model.BlockReason` and `Amphora.BlockReason` on 2026-09-03. A reason one
port cannot produce is still worth naming here, because the registry column is shared and a
reader joining rows across platforms will meet both.

`EXPIRED` is deliberately **not** folded into `FAILED`. It is recoverable — from offset zero,
if the source still exists — and the UI affordance ("restart this upload") differs from the
one for a genuinely dead job.

---

## 2. Transition table

```
                    ┌──────────────────────────────────────────┐
                    ▼                                          │
  Enqueue ──▶ PENDING ──▶ PREPARING ──▶ CREATING ──▶ UPLOADING ─┼──▶ FINALIZING ──▶ COMPLETED
                 │            │             │            │      │        │
                 │            │             │            │      │        └─(ack fails)─┐
                 │            ▼             ▼            ▼      │                      │
                 │        (source          (create      (transport                     │
                 │         missing)         4xx)         error)                        │
                 │            │             │            │                             │
                 └────────────┴─────────────┴────────────┴─────────────────────────────┘
                                            │
                              ┌─────────────┼──────────────┐
                              ▼             ▼              ▼
                          PAUSED        BLOCKED       RETRY_WAIT ──(attempts exhausted)──▶ FAILED
                              │             │              │
                              └─────────────┴──────────────┘
                                            │  (Resume / gate clears / deadline)
                                            ▼
                                       UPLOADING

  Cancel ─────▶ CANCELED   (legal from every non-terminal state)
  process start ─▶ RECOVERING (for every non-terminal job) ─▶ see §5
```

Formally, as `(state, event) → state'`:

| From | Event | To | Side effect |
|---|---|---|---|
| — | `Enqueue` | `PENDING` | insert row, assign client `id` |
| `PENDING` | `Schedule` | `PREPARING` | acquire lease (§4, I8) |
| `PREPARING` | `SourceResolved` | `CREATING` | persist `fingerprint`, `sizeBytes`, `stagedPath?` |
| `PREPARING` | `SourceMissing` | `FAILED(SOURCE_GONE)` | release reservation |
| `PREPARING` | `SpaceDenied` | `BLOCKED(STORAGE_LOW)` | — |
| `CREATING` | `RemoteCreated(url, expiresAt)` | `UPLOADING` | **persist `uploadUrl` before any PATCH** (I2) |
| `CREATING` | `TransportError(retryable)` | `RETRY_WAIT` | `attemptCount++` |
| `CREATING` | `TransportError(fatal)` | `FAILED` | release reservation |
| `UPLOADING` | `OffsetAdvanced(n)` | `UPLOADING` | persist `serverOffset` on ack only |
| `UPLOADING` | `TransportComplete` | `FINALIZING` | — |
| `UPLOADING` | `TransportError(retryable)` | `RETRY_WAIT` | `attemptCount++`, compute `nextAttemptAt` |
| `UPLOADING` | `Blocked(reason)` | `BLOCKED(reason)` | abort attempt, keep record |
| `UPLOADING` | `Pause` | `PAUSED` | abort attempt, keep record |
| `UPLOADING` | `Gone(404\|410)` | `EXPIRED` | clear `uploadUrl`, release reservation |
| `UPLOADING` | `OffsetDiverged(server < local)` | `EXPIRED` | see I7 |
| `FINALIZING` | `ServerAck` | `COMPLETED` | release reservation, delete staged copy, `completedAt` |
| `FINALIZING` | `TransportError(retryable)` | `RETRY_WAIT` | re-`HEAD` on next attempt |
| `RETRY_WAIT` | `DeadlineReached` | `UPLOADING` | via `HEAD` (I1) |
| `RETRY_WAIT` | `AttemptsExhausted` | `FAILED` | release reservation |
| `BLOCKED` | `GateCleared` | `UPLOADING` | via `HEAD` (I1) |
| `PAUSED` | `Resume` | `UPLOADING` | via `HEAD` (I1) |
| any non-terminal | `Cancel` | `CANCELED` | `DELETE uploadUrl` (best-effort, §6), release reservation |
| any non-terminal | `ProcessStart` | `RECOVERING` | §5 |
| `EXPIRED` | `Retry` | `PENDING` | clear offsets, restart from zero |
| `FAILED` | `Retry` | `PENDING` | reset `attemptCount` |

Every other pair is a no-op that **must be logged, not thrown**. A state machine that crashes
on an unexpected event is a state machine that loses uploads in the field.

---

## 3. Events

This is the closed set, read from `dev.amphora.model.UploadEvent` and `Amphora.UploadEvent` on
2026-09-03. Both ports declare the same members in the same three groups, and every one of the 21
names below appears as an `event.type` in `Tests/Conformance/vectors.json` — the set below and the
set the fixture drives are the same set.

**Commands** (from the host app, always valid to issue, may be no-ops)
`Enqueue` · `Schedule` · `Pause` · `Resume` · `Cancel` · `Retry`

`Enqueue` is the one command that is not an input to `reduce`: it *creates* the row rather than
transitioning one, which is why exactly one vector (`row-01-enqueue`) is non-reducing and both
ports assert that count. `Schedule` is the scheduler picking the row up afterwards.

**Transport signals** (from the source resolver and the transfer layer)
`SourceResolved{sizeBytes, fingerprint, stagedPath?}` · `SourceMissing` ·
`RemoteCreated{uploadUrl, expiresAt?}` · `OffsetAdvanced{serverOffset}` · `TransportComplete` ·
`ServerAck` · `TransportError{class, detail?}` · `Gone` · `OffsetDiverged{serverOffset}`

**Environment signals** (from the governors and the scheduler)
`Blocked{reason}` · `GateCleared` · `SpaceDenied{needed}` · `DeadlineReached` ·
`AttemptsExhausted` · `ProcessStart`

The environment group is deliberately **reason-carrying rather than cause-named**: the governors
decide *whether* a gate is shut and name it in `BlockReason`; the state machine only needs
`Blocked` and `GateCleared`. A per-cause event set (`NetworkLost`, `StorageLow`, `PowerLow`,
`StorageOk`, `FgsQuotaExhausted`) would put the same taxonomy in two places — `BlockReason` and the
event enum — where they can disagree, and would force every new gate to touch `reduce`.

`TransportError` classes, because the retry policy hangs off them. Seven, not five —
`ErrorClass` in both ports:

| Class | Examples | Policy |
|---|---|---|
| `TRANSIENT` | connection reset, timeout, network switch, 5xx, 429 | retry with backoff; **does not** count toward the fatal threshold if the offset advanced |
| `AUTH` | 401, 403, expired signature | one silent refresh attempt via the token provider, then `FAILED(AUTH)` |
| `PROTOCOL` | 409 offset conflict, 460 checksum mismatch | re-`HEAD`, resume from server truth, count as an attempt |
| `PROTOCOL_VERSION` | 412 — an unpinned or unsupported `Tus-Resumable` / interop version | `FAILED`. Never an implicit fallback to a non-resumable upload; see `wire-protocol.md` |
| `FATAL` | 413 too large, 400 malformed | `FAILED` immediately, no retry |
| `LOCAL` | disk full mid-write; on iOS, a refused remainder-staging reservation | `BLOCKED(STORAGE_LOW)`. Always blocked, never failed — it is a gate, not a defect |
| `SOURCE_GONE` | the source file or asset no longer resolves | `FAILED(SOURCE_GONE)` — the §2 `PREPARING`+`SourceMissing` row |

The `.http(code)` → class mapping is written **once**, in `HTTPStatus.classify`; it used to be
restated verbatim in `TransportError.errorClass` and was collapsed in `afabf05`
([dead-code-removal.md](dead-code-removal.md)). Nothing in the fixture asserts the classification —
see [conformance-vectors.md §3.1](conformance-vectors.md#31-fields-the-fixture-states-and-neither-port-reads).

Note the "does not count if the offset advanced" rule. Without it, a 4 GB upload on a flaky
train Wi-Fi exhausts its retry budget while making steady forward progress — which is the
single most common way a technically-correct uploader fails a real user.

---

## 4. Invariants

These are the assertions the test suite exists to defend.

- **I1 — The server's offset is the only authority.** `bytesTransferred` is a display hint.
  Every entry into `UPLOADING` from a non-`UPLOADING` state is preceded by a `HEAD` (or by a
  cached `serverOffset` written from an acked response within the last few seconds).

- **I2 — Persist before you act.** `uploadUrl` is durably written *before* the first byte is
  sent. Violating this orphans a server-side resource that can never be resumed **or deleted**,
  because tusd has no enumeration endpoint (`persistence-and-recovery.md` §4).

- **I3 — No bytes in flight without a durable record.** Corollary of I2.

- **I4 — Terminal states absorb.** The one exception is `CANCELED`, which may carry pending
  async cleanup (`remoteTerminated: bool`) — see §6.

- **I5 — A storage reservation is held across `PREPARING`→`FINALIZING` and released on every
  exit path**, including crash. Crash-path release is the reconciler's job (§5, step 5).

- **I6 — No chunk temp file outlives a single transport attempt.** The default path
  materializes *zero* chunk files: byte ranges stream from the source. This is the invariant
  that retires the original `TransferUtility` corruption bug rather than working around it.
  It is the one invariant here with transport-level vectors of its own
  (`transportInvariants.i6NoChunkTempFiles`, run by both ports) rather than transition rows,
  because a port that stages "just the remainder" satisfies every row in the table while doubling
  peak storage. See [conformance-vectors.md](conformance-vectors.md).

- **I7 — Offsets are monotonic.** A server offset lower than a previously acked one means the
  resource was recycled underneath us. Treat as `EXPIRED`; never "resume" downward.

- **I8 — At most one runner per job, enforced by a durable lease.** A row holds
  `ownerToken` + `leaseExpiresAt`; a runner renews while active. Two concurrent `PATCH`es on
  one upload URL produce silent corruption, and it is genuinely reachable — a re-enqueued
  WorkManager job racing a resurrected `URLSession` task after relaunch is the exact scenario.

- **I9 — Progress is coalesced at the boundary.** State changes cross the native↔JS bridge
  immediately; byte progress is throttled to ≤1 Hz per job plus a final flush.

---

## 5. Recovery is a transition, not a special case

`ProcessStart` is an ordinary event. See `persistence-and-recovery.md` for the full algorithm;
the state machine's contribution is that every non-terminal job enters `RECOVERING` and leaves
it by exactly one of: `UPLOADING`, `PAUSED`, `BLOCKED`, `PENDING`, `FINALIZING`, `EXPIRED`,
or `FAILED(SOURCE_GONE)`.

---

## 6. Cancelation must work on a job the app has never seen running

A job canceled while orphaned still needs its server resource reclaimed. Because `uploadUrl`
was persisted before the first byte (I2), `DELETE uploadUrl` (tus Termination extension) is
always issuable. If the device is offline at cancel time, the job moves to `CANCELED` with
`remoteTerminated = false` and the termination is retried opportunistically on later launches.

Server-side backstop, since tusd will not do this for you: an S3 lifecycle rule with
`AbortIncompleteMultipartUpload` bounds the cost of terminations that never arrive.

---

## Corrections

**2026-09-03, tasklist `901-docs-tell-the-truth`.** §3 was written before either port existed and
had never been read back against one. Four things it said were not true of the code, and because
this file is the *normative* home for behaviour, each was a claim a reader had no reason to doubt.
Read from `dev.amphora.model.UploadEvent` / `UploadJob.kt` and `Amphora.UploadEvent` /
`UploadJob.swift`, cross-checked against the 21 `event.type` values in
`Tests/Conformance/vectors.json`.

| §3 said | The tree says | Resolution |
|---|---|---|
| `SetPriority` is a command | No such event in either port. Priority is a field on `UploadPolicy`, set at enqueue, never an event | Removed. `Schedule` — which *is* an event, drives `PENDING`→`PREPARING`, and appears in §2 — was missing and is now listed |
| Environment signals are `NetworkAvailable`, `NetworkLost`, `StorageLow`, `StorageOk`, `PowerLow`, `FgsQuotaExhausted` | Five of those six do not exist. Both ports carry `Blocked{reason}` / `GateCleared`, with the cause in `BlockReason` | Replaced with the implemented set, and the design reason is now stated rather than left to look like an oversight. §2's `UPLOADING` row named the same three phantom events and now names `Blocked(reason)` |
| Transport signals begin at `RemoteCreated` | `SourceResolved` and `SourceMissing` are transport-group events in both ports, and §2 already had rows for both | Added |
| Five `TransportError` classes | Seven. `SOURCE_GONE` and `PROTOCOL_VERSION` were missing — and §2 line for `PREPARING`+`SourceMissing` was already spelling `FAILED(SOURCE_GONE)`, so the document contradicted itself | Added, with the `412` mapping read off `HTTPStatus.classify` |

Two smaller ones in the same pass:

- **`LOCAL` was documented as "`BLOCKED` or `FAILED` depending on recoverability".** Neither port
  branches: `UploadStateMachine.swift:212` and `UploadStateMachine.kt:181` both return
  `BLOCKED(STORAGE_LOW)` unconditionally. The doc offered a discretion the code does not have.
- **§1's `blockReason` list was the Kotlin enum.** Swift declares `REMAINDER_STAGING_DENIED` and
  not `FGS_QUOTA_EXHAUSTED`; the list is now per-port, because the column is shared.

**What this pass did not do.** It did not change any transition, any port, or any vector — the two
ports already agreed with each other and with the fixture, and this document was the outlier. It
also did not verify that §2's table is *complete* with respect to `reduce`; every row in it was
checked to exist, but a transition the code implements and this table omits would not have been
caught by reading in this direction.
