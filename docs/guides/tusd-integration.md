# Real tusd integration

> **Status:** Live · **Updated:** 2026-09-03 · **Owner:** Daniel DeKerlegand

The wire layers are exercised against the pinned server and an S3-compatible backend by
[`integration/tusd/run.sh`](../../integration/tusd/run.sh). The environment uses tusd v2.4.0,
MinIO as the S3 backend, and fixed credentials that are local to the disposable Compose stack.
No production credentials are needed.

## What the exit code means

The harness is three-valued, and the distinction is the point:

| Exit | Meaning |
| --- | --- |
| `0` | The run happened against a live daemon and it passed. |
| `1` | The run happened and it failed. |
| `77` | The run did **not** happen — no Docker here. Nothing was proven either way. |

A two-valued harness cannot tell "could not run" from "ran and passed", and tasklist `80` recorded
a live-run story as passing on a machine whose Docker daemon was never reachable. Never convert a
`77` into a pass. Where a skip must be red instead — CI, or any run whose purpose is to produce
evidence — set `AMPHORA_REQUIRE_DOCKER=1` and the same condition exits `1`.

## Image pins

Every image in [`docker-compose.yml`](../../integration/tusd/docker-compose.yml) is pinned by
**digest**, with the human-readable release in a comment beside it. The previous `RELEASE.*` tag
pins for MinIO were withdrawn from Docker Hub and the harness failed at `compose up` everywhere —
a tag is mutable inventory that a publisher can prune, while a digest is content-addressed and
cannot be repointed. `mc` ships inside the `minio` image, so there is no separate `minio/mc` pin to
rot. To bump: pull the tag, read `docker image inspect --format '{{index .RepoDigests 0}}'`, and
update both the digest and the release comment together.

## Run it

Requirements: Docker with Compose v2, `curl`, Python 3, and `shasum`.

```sh
integration/tusd/run.sh
```

The script creates a deterministic 3 MiB source, then performs `POST` (create), `HEAD`, `PATCH`
(append), and `DELETE` (terminate). It checks the acknowledged `Upload-Offset`, rejects a request
with an unpinned `Tus-Resumable` value, and performs a second `HEAD` to prove termination returned
404 or 410. The Compose teardown removes the disposable MinIO volume on exit.

## Verify process-death resume and bytes at rest

```sh
integration/tusd/resume.sh
```

This opt-in check kills a deliberately throttled PATCH process after tusd has acknowledged a
non-zero partial offset. A fresh process performs `HEAD`, resumes from that server offset, and then
reads the tusd S3 object through MinIO to compare SHA-256 with the deterministic source. (tusd's S3
upload id is `<object-key>+<s3-multipart-upload-id>`; only the part before the `+` names the object,
and `mc`'s alias must be created in the same container shell that reads it. Both were wrong here
until the script was first actually run.) The per-port equivalents are below. The script requires the same Docker/Compose, `curl`, Python 3, and `shasum` prerequisites, and
follows the same exit-code contract.

## Put the ports on the wire

`run.sh` and `resume.sh` drive the **server** with curl. They say nothing about whether the Swift
and Kotlin ports work, which is a different claim and the one that matters. Each port has its own
harness.

### Swift — `integration/tusd/swift-wire.sh`

```sh
integration/tusd/swift-wire.sh
```

It uploads 8 MiB in two halves across a **real process death**. The first process sends a 5.25 MiB
prefix — deliberately over the 5 MiB S3 multipart minimum, so tusd has flushed a genuine part into
MinIO — and then calls `kill(getpid(), SIGKILL)` on itself. The driver asserts on **exit status
137**, because a signal death and an `exit(1)` must not be confusable. A second process, handed
nothing but the upload URL on its command line, recovers the offset with `HEAD` and finishes. The
object is then read back out of MinIO and its SHA-256 compared with the source.

This replaced a harness that "simulated process death" by allocating a second `ControlPlaneClient`
in the same process. That demonstrates an object with no cached offset; it does not demonstrate
that the *process* can die, which is the product thesis.

Observed on 2026-08-27 against Docker server 29.3.1:

```
sent 5505024 bytes, tusd acked offset 5505024; now killing pid 6691 with SIGKILL
sender died: exit status 137 (SIGKILL)
resumed from server offset 5505024 and completed at 8388608 of 8388608
bytes at rest in MinIO match the source: sha256 bdf23837181f5808331800c1ae2b4f7d7a839536b10d58491471c50dde23833a
unpinned Tus-Resumable rejected with HTTP 412
terminated; HEAD now returns HTTP 404
peak extra disk during transfer: 4 KiB (baseline 8192 KiB, peak 8196 KiB) for a 8192 KiB upload
```

The individual phases can also be driven by hand against a stack you already have up:

```sh
url=$(swift run --package-path ios AmphoraTusdIntegration create http://127.0.0.1:8080/files/ 8388608)
swift run --package-path ios AmphoraTusdIntegration resume "$url" /path/to/source.bin
```

Running the binary with no arguments and `TUSD_ENDPOINT` set performs the old single-process
smoke test. That is a smoke test, not evidence of resume across process death — only the driver
above is that.

### Kotlin — `dev.amphora.TusdIntegrationTest`

```sh
TUSD_ENDPOINT=http://127.0.0.1:8080/files/ \
AMPHORA_REQUIRE_DOCKER=1 \
  ./gradlew :android:testDebugUnitTest --tests 'dev.amphora.TusdIntegrationTest'
```

The interruption here is an aborted request rather than a killed process: the second `PATCH` is cut
off from inside `RangeRequestBody` via the production `SliceDeadlineReached` path — the one
Android 15's foreground-service budget actually triggers — which kills the connection mid-body with
a full `Content-Length` still outstanding. A brand-new `OkHttpClient` then re-establishes the offset
with `HEAD` and completes the upload, and the stored object is downloaded back from tusd and
checksummed.

Without `TUSD_ENDPOINT` the test skips and says so. With `AMPHORA_REQUIRE_DOCKER=1` a skip becomes
a failure — same contract as the shell harnesses, for the same reason.

## Where each of these runs

| Harness | Runs in CI? | Why |
| --- | --- | --- |
| `run.sh`, `resume.sh`, `swift-wire.sh` | No | GitHub's `macos-*` runners have no Docker daemon, and the Swift toolchain is only on the macOS runner. Run them locally. |
| `TusdIntegrationTest` | Yes — the `android` job | `ubuntu-latest` has Docker, and no JDK exists on the machines these stories are written on, so CI is the only place the Kotlin port can be put on a socket at all. |

The `android` job stands the Compose stack up, runs the test with `AMPHORA_REQUIRE_DOCKER=1`, and
prints `android/build/reports/tusd-real-wire.txt` — the line the test writes recording how many
bytes moved, from which resumed offset, and how much disk it cost.

## The storage claim is measured, not asserted

Invariant I6 says the transports never stage a chunk file: the remainder is streamed from the
original source, so peak extra storage is about zero. Both harnesses **sample** that rather than
reasoning about it. `swift-wire.sh` redirects `TMPDIR` into a scratch tree and polls `du -sk` every
50 ms for the length of the transfer; the Kotlin test gets a per-run `java.io.tmpdir` (set in
`android/build.gradle.kts`) and samples it every 25 ms. Both take a baseline with the source
already in place and fail if the peak exceeds it by more than 256 KiB.

For scale: a transport that staged only the remainder would need about 2.75 MiB of the 8 MiB
transfer; one that staged the whole file, 8 MiB. The Swift run above measured **4 KiB**.

Both clients use the tus 1.0 dialect expected by tusd v2 and the shared pinned version `1.0.0`. The
RUFH interop pin used by the native iOS path remains separately pinned to `8` in
`TusProtocol`/`TusTransport`; a server returning an unsupported version is a protocol error, never
an implicit fallback.
