# Wire protocol

> **Status:** Draft · **Updated:** 2026-08-19 · **Owner:** Daniel DeKerlegand

Two dialects, one transport interface. They are **not** cosmetic variants of each other — header
names, content types, and expiry semantics all differ — so the seam is explicit rather than a set
of conditionals sprinkled through the transport.

| | **tus 1.0** (`Tus10`) | **RUFH** (`Rufh`, draft-11) |
|---|---|---|
| Version header | `Tus-Resumable: 1.0.0` on every request/response | `Upload-Draft-Interop-Version: <n>` |
| Create | `POST` + `Upload-Length`, `Upload-Metadata` | `POST` + `Upload-Complete: ?1`, `Upload-Length` |
| Create response | `201 Created` + `Location` | `104 Upload Resumption Supported` + `Location` |
| Offset query | `HEAD` → `200`/`204` + `Upload-Offset` | `HEAD` → `204` + `Upload-Offset`, `Upload-Complete` |
| Append | `PATCH` + `Upload-Offset` | `PATCH` + `Upload-Offset`, `Upload-Complete` |
| Append content type | `application/offset+octet-stream` | `application/partial-upload` |
| Append response | `204` + `Upload-Offset` | `204` + `Upload-Complete` |
| Offset mismatch | `409 Conflict` | `409 Conflict` |
| Expiry | `Upload-Expires` (RFC 9110 date) | `Upload-Limit: max-age=<seconds>` |
| Server limits | — | `Upload-Limit: max-size, min-size, max-append-size, min-append-size, max-age` |
| Terminate | `DELETE` + `Content-Length: 0` → `204` | `DELETE` → `204` |

Both: a terminated or expired upload URL answers `404` or `410` thereafter, which the state
machine reads as `.expired`.

## `Upload-Metadata` encoding (tus 1.0 only)

Comma-separated pairs; key and value separated by a **space**; the value base64-encoded:

```
Upload-Metadata: filename d29ybGRfZG9taW5hdGlvbl9wbGFuLnBkZg==, contentType dmlkZW8vbXA0
```

Keys must not contain spaces or commas. RUFH has no metadata header — carry it in ordinary
request headers or in the creation URL, which is why `endpoint` is per-job rather than global.

## `Location` may be relative

tus explicitly permits it, and tusd behind a reverse proxy commonly returns one. Resolving it
against the creation endpoint is mandatory — storing a relative URL as `uploadUrl` produces a job
that can never be resumed *or* terminated after restart, since nothing else on the device records
the base. This is the single most common tus client bug.

## The iOS interop-version hazard

`URLSession`'s native resumable upload (iOS 17+) implements whichever draft revision Apple
shipped. tusd implements whichever revision it was built against. The draft carries an
`Upload-Draft-Interop-Version` precisely because these drift, and **when they do not match, the
upload does not fail — it silently proceeds as an ordinary non-resumable upload.**

That degradation is invisible unless you look for it: transfers work fine until the first
interruption, then restart from zero.

Detection is the `104` informational response. `BackgroundSessionManager` records whether one
arrived per job:

- `104` received → native resumption is live; the system owns offset management.
- no `104` by first body bytes → **we are not resumable**. The job is marked
  `nativeResumeUnavailable`, and the engine drives its own `PATCH`-based resume instead of
  trusting the system.

Verify the actual version pair against your deployed tusd before shipping, and treat
`nativeResumeUnavailable` as a metric worth alerting on — a tusd upgrade can flip an entire
install base into non-resumable mode with no error anywhere.
