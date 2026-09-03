# Amphora documentation

> **Status:** Draft · **Updated:** 2026-09-03 · **Owner:** Daniel DeKerlegand

Every document in this repository is linked from here. Unlinked is unreachable, and unreachable
documentation still greps as current.

## Where this is

- [Roadmap](../ROADMAP.md) — the measured position as of 2026-08-27, the phases named for what
  remains (a total gate, binding vectors, a gated real-wire environment, the 40 device cells, the
  storage governor under genuine pressure, host adoption, publication), the three non-goals
  including the no-chunk-temp-files commitment, and the open decisions.
- [Changelog](../CHANGELOG.md) — what changed and when, under `[Unreleased]` because nothing is
  released yet. Entries dated before 2026-08-27 were reconstructed from git history and the tasklist
  records, and are marked as such; one of them records a correction rather than the original claim.
- [Working in this repository](../CLAUDE.md) — orientation for a session, covering what the tree does
  not state: the adopt-the-protocol boundary, the no-chunk-temp-files commitment, why a `SKIPPED`
  check is never a passing one, and why `swift test` reports "no tests found" while the suite passes.

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
- [Environment verification matrix](reference/environment-matrix.md) — the OS × transport ×
  source × interruption evidence ledger, including explicit physical-device gaps.
- [Environmental claim evidence](reference/environment-evidence.md) — observed automated evidence,
  device-only gaps, and commands required to close them.
- [Conformance vectors](reference/conformance-vectors.md) — the one fixture both ports read: what
  the 40 transition rows and 3 transport rows actually assert, the fields they state but nobody
  checks, the invariants with no vector at all, and the committed negative control that proves the
  suite catches drift instead of merely reporting agreement.
- [Continuous integration](reference/continuous-integration.md) — the remote, the deliberate
  public-visibility decision and its billing reason, and why the workflow triggers on `push`
  rather than `pull_request`. Also the three-outcome verify policy: why a SKIPPED check is
  tolerated on a developer machine and fatal in CI, and never reads as a pass in either.
- [Licensing](reference/licensing.md) — why MIT rather than Apache-2.0 or a reciprocal licence, the
  dependency audit behind that choice (including the one AGPL component in the test harness and why
  nothing travels inward from it), and the file-level convention: root `LICENSE` plus SPDX in each
  distributable manifest, no per-file headers.
- [Dead-code inventory](reference/dead-code-inventory.md) — the candidate list a human approves
  before anything is deleted: nine reproducible searches and their scopes, six genuinely-dead
  findings, eight things that fail a static search and are nonetheless load-bearing (ten Room
  `@TypeConverter`s among them), three intra-port duplications ranked by what drift would cost, and a
  first sketch of what a static search over this tree cannot see — corrected in place from four
  classes to six by the undecidable register below.
- [Dead-code removal record](reference/dead-code-removal.md) — what the inventory proposed versus
  what happened: four removals, one commit each, and the three candidates that survived with the
  reason each survived — including the one whose evidence in the inventory turned out to be wrong.
- [What the dead-code sweep could not decide](reference/dead-code-undecidable.md) — the register of
  candidates the method could not resolve, left in place: six blind-spot classes rather than the
  four the inventory named, including the public API of both ports (`AmphoraUploader` is referenced
  nowhere outside the file that declares it, on either platform), `BlockReason.powerLow` — zero
  references in *both* ports and reached live from a conformance vector by string — and the edges
  that exist only across an OS-initiated relaunch. Also the limits of the method itself.
- [The verification record](reference/verification-record.md) — the rule that a story may not be
  marked passing on work its own notes record as not having run, what breaking it cost this
  repository at tasklist `80`, and what an evidence-bearing note has to contain.

## Guides

- [iOS host integration](guides/ios-host-integration.md) — the two mandatory app-delegate call
  sites.

## Decisions

_None recorded yet. Two are outstanding and should land here:_

- _`0001-adopt-rufh-build-clients.md` — the build-vs-adopt analysis that motivated this repository._
- _`0002-ios-deployment-target.md` — iOS 17 minimum vs. carrying the pre-17 remainder-staging path.
  See [iOS background transfer §4](reference/ios-background-transfer.md)._
