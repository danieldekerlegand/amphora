# Platform constraints

> **Status:** Draft · **Updated:** 2026-08-19 · **Owner:** Daniel DeKerlegand

Hard limits discovered during the build-vs-adopt research. Each one shapes the design; none of
them is negotiable, and several are the reason an off-the-shelf client cannot be used as-is.

---

## 1. iOS

**Background transfers are OS-driven, not app-driven.** A background `URLSession` upload task
continues while the app is suspended or terminated, and the system relaunches the app to
deliver completion. The app does not get to run a transfer loop.

**Therefore: one task per file, not one task per chunk.** TUSKit's own documentation calls
chunking "strongly discouraged" with background sessions, because each chunk needs a fresh
request that the app must be alive to issue. Combined with state-machine I6 (no chunk temp
files), this settles the iOS transport: a single whole-file upload task, resumed by byte offset.

**iOS 17+ gives resumption natively.** `cancelByProducingResumeData()` /
`uploadTask(withResumeData:)` implement the IETF resumable-upload draft, discover server support
via the `Upload-Incomplete` header, and — on background sessions — resume automatically across
interruptions with no app code. Below iOS 17, the system retries **from the beginning**, so
TUSKit is the fallback transport there.

**Configuration that matters:**
- `isDiscretionary = true` lets the system pick a good moment — but uploads may be deferred for
  hours. Ship it `true`; force `false` in debug builds or nothing is testable.
- `waitsForConnectivity` is ignored on background sessions (they always wait).
- `allowsConstrainedNetworkAccess = false` respects Low Data Mode.
- `countOfBytesClientExpectsToSend` improves scheduling for large uploads.

**Storage:** stage into **Application Support**, never `Caches` or `tmp`. Apple's "the Caches
directory is never purged while your app is running" guarantee does not help a background
upload — the app is *suspended*, which is precisely when purging happens. Check headroom with
`volumeAvailableCapacityForImportantUsage`.

**No parallel parts.** TUSKit does not implement the concatenation extension, and the native
iOS 17 path is single-stream by construction. This caps throughput on fast networks. Accepted:
storage safety was the requirement that failed in production, throughput was not.

---

## 2. Android

**There is no OS-managed background upload.** Everything runs in our process, which makes
Android the platform with the most code — and the reason the existing `tus-android-client`
(Java, v0.1.12, a `SharedPreferences` wrapper over `tus-java-client`) does not get us far.

**Android 15 caps `dataSync` foreground services at 6 hours per 24.** On exhaustion the system
calls `Service.onTimeout()`, gives a few seconds to `stopSelf()`, and then throws
`RemoteServiceException`. Starting another `dataSync` FGS raises
`ForegroundServiceStartNotAllowedException` until the user brings the app to the foreground,
which resets the budget.

This is the single most design-forcing constraint on the platform, and it rules out "hold a
foreground service until the 40 GB upload finishes." The response:

- Each `UploadWorker` execution is **bounded** — it uploads until a byte ceiling or a time
  ceiling, persists the acked offset, and re-enqueues its successor.
- Track cumulative FGS seconds; approaching the cap, stop cleanly and move the job to
  `BLOCKED(FGS_QUOTA_EXHAUSTED)`.
- `onTimeout()` is a first-class event, not a crash path: persist offset, stop, block the job.
- Resume when the budget refreshes or the user next foregrounds the app.

Bounded workers happen to solve WorkManager's own ~10-minute execution expectation too, so the
same mechanism covers both limits.

**Streaming, not chunk files.** A bounded worker still streams a byte *range* out of the source
via a custom `RequestBody` — bounded execution and zero temp files are compatible, and both are
required.

**Storage reservation is real on Android.** `StorageManager.getAllocatableBytes(uuid)` reports
what the system would free for you; `allocateBytes(FileDescriptor, long)` **reserves** it
against cache eviction. Documented constraint: for progressively growing allocations, call no
more than once per 60 seconds.

**Network transitions.** A Wi-Fi→cellular switch kills the socket. That is a `TRANSIENT`
transport error followed by `HEAD` and resume — **never** a job failure. `NetworkCallback`
supplies `NET_CAPABILITY_NOT_METERED` and `TEMPORARILY_NOT_METERED` for policy decisions.

---

## 3. React Native

**No transfer logic in JavaScript.** JS does not run while the app is suspended, so any
JS-driven loop fails the backgrounding requirement by construction. This is why every existing
RN option falls short, not an incidental quality problem with them.

The RN layer is a **control surface only**: commands in, coalesced events out, over a
TurboModule. The state machine lives in Swift and Kotlin.

**Progress must be coalesced natively** (state-machine I9). Emitting an event per flush for a
4 GB upload saturates the bridge and stalls the UI thread.

---

## 4. Server (tusd)

- tusd **v2.10.0** speaks tus 1.0 and the IETF draft, with an S3 backend.
- **No Expiration extension** — abandoned uploads need `tusd-cleaner` on a schedule or an S3
  `AbortIncompleteMultipartUpload` lifecycle rule.
- **No enumeration endpoint** — see `persistence-and-recovery.md` §4 for the control-plane
  mitigation.
- **S3 minimum part size is 5 MB.** tusd's `S3Store` buffers incoming `PATCH` bodies on server
  disk to satisfy it and to compute checksums. Size instance storage accordingly; this is a
  capacity-planning item, not a client concern.

---

## 5. Protocol

`draft-ietf-httpbis-resumable-upload` is at **-11 (2 March 2026)**, Standards Track, **not yet
an RFC**. It carries an explicit **interop version** that increments on breaking changes, and
client and server negotiate on it.

Pin the interop version in the transport layer and surface a mismatch as
`FAILED(PROTOCOL_VERSION)` with a distinct code, so a server upgrade that outruns a deployed
app population is diagnosable from crash telemetry rather than presenting as generic upload
failure.
