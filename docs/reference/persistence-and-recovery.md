# Persistence and recovery

> **Status:** Draft · **Updated:** 2026-09-03 · **Owner:** Daniel DeKerlegand

How a job survives the app being closed, killed, crashed, updated, or the device rebooted —
and how it is found again on the next launch.

---

## 1. Two registries, and the join between them

There are always **two** records of an in-flight upload, and neither alone is sufficient:

| Registry | Owner | Survives | Knows |
|---|---|---|---|
| **Job registry** | us (SQLite / Room / Core Data) | process death, reboot, app update | intent, source, `uploadUrl`, policy, history |
| **Platform task registry** | the OS | process death; iOS also survives termination | whether bytes are *actually moving right now* |

- **iOS** — a background `URLSession` created with a **stable identifier** keeps its tasks alive
  across app termination; the system relaunches the app into the background on completion. You
  rediscover them by recreating the session with the same identifier and calling
  `getAllTasks()`. Apple's guidance is explicit: exactly one background session, stable
  identifier, recreate it early in launch before events arrive.
- **Android** — WorkManager persists work in its own database across process death *and*
  reboot. You rediscover via `getWorkInfosByTag("amphora-job:<id>")`.
- **Web** — no platform registry at all. The job registry lives in IndexedDB and every
  interrupted upload is an orphan by definition; recovery is `HEAD` on every launch.

**Reconciliation is the join.** The job registry says what *should* be happening; the platform
registry says what *is*. Everything the user asked for — "find the job again, resume it or
cancel it" — falls out of doing that join correctly on every process start.

---

## 2. Job registry schema

One table, one row per job. **Field names below are normative; the storage engine is not** — and
the two ports take that literally. Kotlin's `UploadJob` is a Room `@Entity`, so each field is a
real column of `upload_job`. Swift's `SQLiteUploadStore` stores the whole `Codable` job as a
`payload BLOB` in `upload_jobs` and projects only what it must query on (`state`,
`remote_terminated`, `staged_path`, `owner_token`, `lease_expires_at`, `completed_at`). Both carry
every field below.

| Field | Notes |
|---|---|
| `id` | client-generated UUID. **The stable public handle.** Never derived from the URL |
| `groupId` | nullable batch label |
| `sourceKind` | Kotlin: `FILE` · `CONTENT_URI` · `STAGED_COPY`. Swift: `file` · `photosAsset` · `securityScoped` · `stagedCopy`. The union is the platform's, not a drift — there is no `PHAsset` on Android and no `content://` on iOS |
| `sourceUri` | original locator, kept even after staging |
| `stagedPath` | non-null **only** when a copy was unavoidable (see §3) |
| `sizeBytes`, `contentType` | |
| `fingerprint` | `hash(sourceUri, sizeBytes, mtime, volumeId)` — **not** a content hash (§6) |
| `endpoint`, `uploadUrl`, `uploadExpiresAt` | `uploadUrl` null until `CREATING` succeeds |
| `metadataJson` | JSON → `Upload-Metadata` |
| `state`, `pauseReason`, `blockReason`, `errorClass`, `errorDetail` | domains in [state-machine.md §1 and §3](state-machine.md) |
| `bytesTransferred` | display hint only |
| `serverOffset`, `serverOffsetAt` | authoritative; only ever written from an acked response |
| `attemptCount`, `nextAttemptAt` | |
| `reservedBytes` | storage reservation held; 0 when none |
| `ownerToken`, `leaseExpiresAt` | single-runner lease (state-machine I8) |
| `policyJson` | JSON `UploadPolicy`: `allowsExpensiveNetwork`, `allowsConstrainedNetwork`, `requiresCharging`, `maxAttempts`, `priority`, `isDiscretionary` |
| `remoteTerminated` | `false` on a `CANCELED` job whose `DELETE` has not landed yet — the deferred-cleanup flag of [state-machine.md §6](state-machine.md) |
| `createdAt`, `updatedAt`, `completedAt` | |
| `schemaVersion` | migration guard across app updates. `1` in both ports |

**Completed jobs are retained**, not deleted, for a configurable window — `pruneCompleted(before:)`
on both stores, called by nothing on a timer yet. "Did my video actually upload last Tuesday?" is a
real question, and a registry that forgets successes cannot answer it.

### Specified here, implemented nowhere: the `upload_event` ring

This document used to state, unqualified, that the schema carries "an append-only, size-bounded
`upload_event` ring per job (state, reason, timestamp, HTTP status)". **It does not.** Neither port
declares such a table; `grep -rn upload_event ios/Sources android/src` returns nothing. The
argument for it stands — field-debugging a stalled 4 GB upload with no local history is guesswork —
so it is kept here as a stated gap rather than deleted, and moved out of the schema table so that
nobody reads it as something they can query today.

---

## 3. Staging: prefer never to copy

Peak extra storage is the whole point (state-machine I6). The decision ladder:

1. **A real file path we can `open()` and seek** → stream byte ranges directly. `stagedPath`
   stays null. Extra storage: **0**.
2. **`content://` on Android** → try `openFileDescriptor` and seek. Many providers support it.
   Extra storage: **0**.
3. **`PHAsset` on iOS, or a non-seekable provider stream** → a copy is unavoidable. Reserve
   space *first*, stage into **Application Support** (never `Caches`/`tmp` — those are exactly
   what the OS purges under disk pressure), mark excluded from backup, record `stagedPath`.

Only case 3 needs the storage governor to hold a reservation, and only case 3 can be blocked
by low disk. Getting 1 and 2 right removes most of the failure surface outright.

---

## 4. What the server does *not* give you

tusd is an offset oracle and nothing more:

- ✅ `HEAD uploadUrl` → `Upload-Offset`. This is the authority (state-machine I1).
- ✅ `DELETE uploadUrl` → Termination extension, reclaims the resource.
- ❌ **No enumeration.** There is no "list my in-progress uploads" endpoint.
- ❌ **No Expiration extension.** tusd does not implement it; abandoned uploads are cleaned up
  by `tusd-cleaner` on a cron, or by an S3 `AbortIncompleteMultipartUpload` lifecycle rule.

**Consequence, and a design recommendation:** if the device's job registry is lost — app
uninstalled, data cleared, user switches phones — the `uploadUrl` is unrecoverable and the
server-side resource is orphaned until a lifecycle rule reaps it.

Since the `POST` that creates an upload already passes through your auth layer, **have the
control plane record `(userId, jobId, uploadUrl, createdAt)` at creation time**. That costs one
row and buys a genuine server-side recovery path: a fresh install can ask your backend "what
was I uploading?" and rehydrate the registry. tusd will not do this for you, and it is the one
piece of the persistence story that has to be built rather than adopted.

---

## 5. The launch reconciler

Runs once per process start, before the host app is told the module is ready.

```
reconcile():
  1. load jobs WHERE state NOT IN (COMPLETED, FAILED, CANCELED)
  2. break stale leases: leaseExpiresAt < now  →  ownerToken = null
  3. ask the platform what is actually alive
       iOS:     session(background, STABLE_ID).getAllTasks()
       Android: WorkManager.getWorkInfosByTag("amphora-job:*")
     for each job:
       live task found      → ADOPT: re-attach delegate, state = UPLOADING, do not restart
       no live task, state was UPLOADING/CREATING/FINALIZING → state = RECOVERING
       everything else      → leave as persisted (PAUSED stays PAUSED, BLOCKED re-evaluates)
  4. for each RECOVERING job:
       a. source still present and fingerprint matches?   no → FAILED(SOURCE_GONE)
       b. uploadUrl is null?                              yes → PENDING (restart from creation)
       c. uploadExpiresAt elapsed?                        yes → EXPIRED
       d. HEAD uploadUrl:
            200/204 + Upload-Offset == sizeBytes  → FINALIZING
            200/204 + Upload-Offset  < sizeBytes  → resumable; serverOffset := header
            200/204 + Upload-Offset  < serverOffset → EXPIRED   (I7: never resume downward)
            404 | 410                              → EXPIRED
            401 | 403                              → refresh token once, else FAILED(AUTH)
            network unreachable                    → BLOCKED(NETWORK_UNAVAILABLE), stay recoverable
       e. re-evaluate gates → UPLOADING | BLOCKED | PAUSED
  5. garbage collect
       staged files with no owning row         → delete
       storage reservations with no owning row → release
       CANCELED rows with remoteTerminated=false → retry DELETE, best effort
  6. emit `ready`; host app may now call getJobs()
```

Step 3's *adopt* branch is the one that is easy to get wrong and expensive to get wrong: if you
blindly restart a job whose iOS background task is still alive, you get two writers on one
upload URL and silent corruption. Hence the lease (I8) *and* the adopt check.

Step 4d is deliberately tolerant of an offline launch. A user who opens the app in airplane
mode must still **see** their pending uploads and be able to **cancel** them; only resumption
needs the network.

---

## 6. Why the fingerprint is not a content hash

Reading 4 GB to compute a digest costs minutes of wall time and a visible chunk of battery,
every launch, for a check that `(uri, size, mtime, volume)` already answers. tus-js-client's
default fingerprint makes the same trade for the same reason.

The residual risk — a file modified in place at exactly the same size and mtime — is accepted.
Where it matters (a source the user can edit), the host app supplies its own `fingerprint`
via the enqueue options and takes responsibility for it.

---

## 7. Schema migration

`schemaVersion` is per row, not per database. An app update that changes the job model must
migrate rows in place; it must **never** drop the table. Dropping it silently orphans every
in-flight server resource, since `uploadUrl` lives nowhere else on the device (§4).

---

## Corrections

**2026-09-03, tasklist `901-docs-tell-the-truth`.** §2 was read field-by-field against
`android/src/main/kotlin/dev/amphora/model/UploadJob.kt`,
`ios/Sources/Amphora/Model/UploadJob.swift`, and the `CREATE TABLE` in
`ios/Sources/Amphora/Store/SQLiteUploadStore.swift`. It named fields that do not exist and omitted
one that does.

| §2 said | The tree says | Resolution |
|---|---|---|
| `metadata` | `metadataJson` in both ports | Renamed |
| `policy` — JSON `allowedNetworks`, `requiresCharging`, `maxAttempts`, `priority` | `policyJson`. `UploadPolicy` has no `allowedNetworks`; the network settings are two booleans, `allowsExpensiveNetwork` and `allowsConstrainedNetwork`, and `isDiscretionary` was missing | Renamed and re-listed |
| `sourceKind` is `FILE · PHASSET · CONTENT_URI · STAGED_COPY` | Neither port declares that set. Kotlin has three, Swift four, and Swift's Photos case is spelled `photosAsset`. `securityScoped` was missing entirely | Both domains are now listed, per port, with why they differ |
| *(no row)* | `remoteTerminated` is a persisted field in both ports and is what makes deferred cancellation survive a restart | Added |
| The schema carries an `upload_event` ring | No such table in either port | Moved out of the table into a section that says plainly it is unimplemented. **Not deleted** — the reason for wanting it is still good, and a stated gap is useful where a false schema row is not |

One softened claim: **"completed jobs are retained for a configurable window"** implied a running
mechanism. `pruneCompleted(before:)` exists on both stores and, as of this date, has no caller
anywhere in the tree — retention is currently unbounded by omission rather than by policy.

**What this pass did not do.** It did not check that the *reconciler* algorithm in §5 matches
`Reconciler.swift` / `Reconciler.kt` step for step; §2 was the section whose claims were
mechanically checkable against a type declaration, and that is the check that was run.
