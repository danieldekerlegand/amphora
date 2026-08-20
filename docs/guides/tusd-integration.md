# Real tusd integration

The wire layers are exercised against the pinned server and an S3-compatible backend by
[`integration/tusd/run.sh`](../../integration/tusd/run.sh). The environment uses tusd v2.4.0,
MinIO as the S3 backend, and fixed credentials that are local to the disposable Compose stack.
No production credentials are needed.

## Run it

Requirements: Docker with Compose v2, `curl`, and Python 3.

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
reads the tusd S3 object through MinIO to compare SHA-256 with the deterministic source. The Swift
and Kotlin integration targets perform the same two-stage exchange by constructing a fresh client
between PATCH requests; both also reject an out-of-range server offset as a typed protocol error.
The script requires the same Docker/Compose, `curl`, Python 3, and `shasum` prerequisites.

## Run the platform clients

The server endpoint is `http://127.0.0.1:8080/files/`. Keep the Compose stack running in one
terminal, then run the platform integration target in the other terminal:

```sh
TUSD_ENDPOINT=http://127.0.0.1:8080/files/ swift run --package-path ios AmphoraTusdIntegration
TUSD_ENDPOINT=http://127.0.0.1:8080/files/ gradle :android:testDebugUnitTest --tests '*TusdIntegrationTest'
```

Both clients use the tus 1.0 dialect expected by tusd v2 and the shared pinned version
`1.0.0`. The RUFH interop pin used by the native iOS path remains separately pinned to `8` in
`TusProtocol`/`TusTransport`; a server returning an unsupported version is a protocol error, never
an implicit fallback.

The integration checks are opt-in because they require Docker and a live server. CI continues to
run the deterministic unit/conformance checks on every change; invoke this guide in a Docker-enabled
integration job or before a server upgrade.
