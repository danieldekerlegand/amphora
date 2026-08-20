# Amphora documentation

> **Status:** Draft · **Updated:** 2026-08-19 · **Owner:** Daniel DeKerlegand

Every document in this repository is linked from here. Unlinked is unreachable, and unreachable
documentation still greps as current.

## Reference

- [Upload state machine](reference/state-machine.md) — states, transitions, events, and the
  invariants the test suite exists to defend. The single source of truth for behaviour; the
  Swift and Kotlin implementations are ports of it.
- [Persistence and recovery](reference/persistence-and-recovery.md) — the durable job registry,
  the platform task registry, and the launch reconciler that joins them. Read this for anything
  involving app restarts, orphaned uploads, or cancelation after termination.
- [Platform constraints](reference/platform-constraints.md) — the hard limits that shape the
  design: iOS background-session semantics, Android 15's foreground-service budget, what tusd
  does and does not provide.
- [Wire protocol](reference/wire-protocol.md) — the two dialects (tus 1.0 and the IETF draft),
  their concrete header differences, `Upload-Metadata` encoding, relative `Location` resolution,
  and the interop-version hazard that can silently disable native iOS resumption.
- [iOS background transfer](reference/ios-background-transfer.md) — session identity, task
  re-identification after relaunch, the two transports and the deployment-target decision
  between them, and the division of labour with the system.

## Guides

- [iOS host integration](guides/ios-host-integration.md) — the two mandatory app-delegate call
  sites.

## Decisions

_None recorded yet. Two are outstanding and should land here:_

- _`0001-adopt-rufh-build-clients.md` — the build-vs-adopt analysis that motivated this repository._
- _`0002-ios-deployment-target.md` — iOS 17 minimum vs. carrying the pre-17 remainder-staging path.
  See [iOS background transfer §4](reference/ios-background-transfer.md)._
