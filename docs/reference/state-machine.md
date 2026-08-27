# Upload state machine

> **Status:** Draft · **Updated:** 2026-08-19 · **Owner:** Daniel DeKerlegand

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

`BLOCKED` carries a `blockReason`: `NETWORK_UNAVAILABLE` · `NETWORK_DISALLOWED` (metered
network, policy forbids) · `STORAGE_LOW` · `POWER_LOW` · `FGS_QUOTA_EXHAUSTED` (Android only,
see `platform-constraints.md` §2) · `CONCURRENCY_LIMIT`.

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
| `UPLOADING` | `NetworkLost` \| `StorageLow` \| `PowerLow` | `BLOCKED(reason)` | abort attempt, keep record |
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

**Commands** (from the host app, always valid to issue, may be no-ops)
`Enqueue` · `Pause` · `Resume` · `Cancel` · `Retry` · `SetPriority`

**Transport signals** (from the platform transfer layer)
`RemoteCreated` · `OffsetAdvanced` · `TransportComplete` · `ServerAck` · `TransportError{class}` ·
`Gone` · `OffsetDiverged`

**Environment signals** (from the governors)
`NetworkAvailable{metered, constrained, expensive}` · `NetworkLost` · `StorageLow{freeBytes}` ·
`StorageOk` · `PowerLow` · `FgsQuotaExhausted` · `ProcessStart`

`TransportError` classes, because the retry policy hangs off them:

| Class | Examples | Policy |
|---|---|---|
| `TRANSIENT` | connection reset, timeout, network switch, 5xx, 429 | retry with backoff; **does not** count toward the fatal threshold if the offset advanced |
| `AUTH` | 401, 403, expired signature | one silent refresh attempt via the token provider, then `FAILED(AUTH)` |
| `PROTOCOL` | 409 offset conflict, 460 checksum mismatch | re-`HEAD`, resume from server truth, count as an attempt |
| `FATAL` | 413 too large, 400 malformed, unsupported version | `FAILED` immediately, no retry |
| `LOCAL` | source unreadable, disk full mid-write | `BLOCKED` or `FAILED` depending on recoverability |

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
