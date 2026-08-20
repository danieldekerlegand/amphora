# Environment verification matrix

> **Status:** Evidence ledger · **Updated:** 2026-08-20 · **Owner:** Amphora

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
the fallback's remainder staging, offset streaming, and pressure-abort behavior. The selector in
`AmphoraUploader` chooses the native implementation on iOS 17+ and the TUSKit fallback below iOS
17. This is automated code-path evidence, not a claim of successful physical-device background
execution; those runtime cells remain **NOT YET VERIFIED** above.

The Android unit and tusd integration tests cover protocol, state, storage, and bounded-worker
logic, but do not cover the OS behaviors listed as physical-device-only. They are not substituted
for those cells.

## Evidence required to close a cell

For each manual cell, capture the device model, OS build, app version, source kind, transport, test
start and end times, interruption action, job ID, server final offset, and final state. Attach the
log or recording to the task result and replace only that cell's verdict with
`MANUAL-ON-DEVICE — <evidence name>`. Automated cells should name the exact command and test that
produced the result.
