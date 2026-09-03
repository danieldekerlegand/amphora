# Environment verification matrix

> **Status:** Evidence ledger · **Updated:** 2026-09-03 · **Owner:** Amphora

This is the execution matrix for the claims in [Platform constraints](platform-constraints.md).
A cell is a verdict for one OS/transport/source/interruption combination, not a claim that a
nearby simulator run is representative. The matrix is intentionally explicit about gaps: a
physical device is required for background budgets, process death, storage reclamation, and radio
transitions.

## Verification labels

Every cell uses exactly one of these labels:

- **AUTOMATED** — reproduced by a checked-in test or integration command; the evidence is named in
  the cell.
- **MANUAL-ON-DEVICE** — reproduced on a physical device; the recording or log is named in the
  cell.
- **NOT YET VERIFIED** — no honest evidence exists yet. When followed by `physical device`, a
  simulator or emulator is explicitly not accepted as a substitute.

The current repository contains no physical-device recordings. Therefore environmental cells are
not upgraded to a simulator result merely to make the table look complete.

## Matrix

The source dimension is platform-specific: iOS has a local file and a Photos asset; Android has a
local file, a seekable content URI, and a non-seekable content URI. The transport is the one chosen
by the OS-version selector, so the two iOS implementations are separate rows.

| OS version | Transport | Source type | App suspended/backgrounded | Process killed and relaunched | Storage reclaimed mid-transfer | Network loss or Wi-Fi→cellular |
|---|---|---|---|---|---|---|
| iOS 17+ | NativeResumableTransport | Local file URL | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device |
| iOS 17+ | NativeResumableTransport | Photos asset | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device |
| iOS 15–16 | TUSKitTransport fallback | Local file URL | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device |
| iOS 15–16 | TUSKitTransport fallback | Photos asset | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device |
| Android 14 | tus transport + bounded worker | Local file | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device |
| Android 14 | tus transport + bounded worker | Seekable content URI | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device |
| Android 14 | tus transport + bounded worker | Non-seekable content URI | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device |
| Android 15 | tus transport + bounded `dataSync` worker | Local file | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device |
| Android 15 | tus transport + bounded `dataSync` worker | Seekable content URI | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device |
| Android 15 | tus transport + bounded `dataSync` worker | Non-seekable content URI | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device | NOT YET VERIFIED — physical device |

## What has been exercised in the repository

Both iOS transport implementations are exercised at the checked-in code-path level: the Swift
package builds `NativeResumableTransport` and `TUSKitTransport`, while `AmphoraPathTests` executes
the fallback's remainder staging, offset streaming, and pressure-abort behavior. The selector is
`TransportSelector.select` in `ios/Sources/Amphora/Transport/UploadTransport.swift`: it returns
`NativeResumableTransport` with a `RufhDialect` under `#available(iOS 17.0, *)` and
`TUSKitTransport` with a `Tus10Dialect` otherwise. `TUSKitTransport` is a file in this repository,
not the TUSKit package — the Swift package declares no external dependencies
([Licensing](licensing.md)). This is automated code-path evidence, not a claim of successful
physical-device background execution; those runtime cells remain **NOT YET VERIFIED** above.

The Android unit and tusd integration tests cover protocol, state, storage, and bounded-worker
logic, but do not cover the OS behaviors listed as physical-device-only. They are not substituted
for those cells.

## Evidence required to close a cell

This is the one home for the closing procedure; [Environmental claim evidence](environment-evidence.md)
points here rather than restating it.

For each manual cell, capture the device model, OS build, app version, source kind, transport, test
start and end times, interruption action, job ID, server final offset, and final state. Attach the
log or recording to the task result and replace only that cell's verdict with
`MANUAL-ON-DEVICE — <evidence name>`. Automated cells should name the exact command and test that
produced the result.

## Corrections

**2026-09-03, tasklist `901-docs-tell-the-truth`.** This file and
[Environmental claim evidence](environment-evidence.md) were the two documents the previous pass
(US-2) did not read; both were still stamped `2026-08-20`. Read here against
`ios/Sources/Amphora/Transport/UploadTransport.swift`.

- **"The selector in `AmphoraUploader` chooses the native implementation on iOS 17+".** There is no
  selector in `AmphoraUploader.swift` and no `#available` check anywhere in that file. The choice is
  made by `TransportSelector.select` in `Transport/UploadTransport.swift`, which also picks the
  matching dialect — `RufhDialect` for the native path, `Tus10Dialect` for the fallback — a
  consequence the old sentence lost. The behaviour it described was right; the place it named was
  not, and this is a document whose whole purpose is to say where evidence was read from.
- **"the TUSKit fallback"** read as though the fallback were the third-party TUSKit package. It is
  `TUSKitTransport`, a file in this repository; `ios/Package.swift` declares no external
  dependencies. [`licensing.md`](licensing.md) has always said so, and the same phrasing was
  corrected in two other documents on 2026-09-03.

**What this pass did not do.** It did not move a cell. All 40 cells still read
`NOT YET VERIFIED — physical device`, no device recording is checked in, and nothing here was
promoted on the strength of a simulator run. It also did not verify that the ten rows are the right
ten — the OS-version and source-kind dimensions are a plan for what to test, not a reading of the
code, and the code does not constrain them.
