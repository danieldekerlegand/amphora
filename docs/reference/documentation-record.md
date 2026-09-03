# The documentation sweep — what was archived, what was left alone, and what it was not

> **Status:** Live · **Updated:** 2026-09-03 · **Owner:** Daniel DeKerlegand

The record of tasklist `901-docs-tell-the-truth`, whose brief was to make the documentation describe
this repository as it *is*. Three things a reader needs from a sweep like this and cannot get by
reading the sweep's diff: **what was archived and why nothing else was**, **what looks stale and was
deliberately kept**, and **what the sweep did not check** — because "the docs are now true" is a
stronger claim than the method supports, and stating it without its limits would repeat the defect
the sweep was cleaning up.

The per-document detail is not here. Eleven files carry a dated `## Corrections` section saying what
that file claimed, what the tree says, and what was read to tell them apart; this is the record of
the pass as a whole.

---

## 1. The archive decision: nothing was archived, and nothing was deleted

**Nothing in this repository met the bar for `docs/archive/`, so `docs/archive/` still does not
exist.** Git cannot track an empty directory, and creating a placeholder to make a layout table look
complete is the same move as filling an unverified matrix cell with a simulator result. When the
first document is superseded it will create the directory; until then this section is the answer to
the question the missing directory raises.

**Nothing was deleted, and nothing has ever been deleted here.** Over the 100 commits since
`bb9f613` (2026-08-20):

```console
$ git log --all --diff-filter=D --format= --name-only -- '*.md' | sed '/^$/d' | wc -l
0
$ git log --all --diff-filter=R --name-status -- '*.md'
R072    android/BUILD.md    docs/reference/android-build.md
```

The single rename is this tasklist's own US-1 move, which repointed nothing because nothing cited the
old path. So the archive-not-delete rule was not merely followed in this pass — there is no prior
deletion for it to have caught, and the record is intact from the first commit.

### What would have to be true to archive a document

Stated now, while there is no pressure on the judgement, so the next pass is not deciding it under
the incentive to tidy:

- Its subject **no longer exists** in the tree, and no other document depends on it as history; **or**
- A named successor document covers the same ground, in which case the original moves to
  `docs/archive/` with `Status: Superseded`, a line naming the successor and the date, and a pointer
  left in `docs/README.md`.

Being *out of date* is not the bar. A stale document gets corrected in place with a `## Corrections`
section — that is the whole method of US-2 and it applied to nine files. Being *historical* is not
the bar either; see §2.

## 2. What looks stale and was deliberately kept

A sweep that only reports what it changed reads as though everything it left alone was checked and
found current. Some of it was checked and found current. Some of it was checked and found to be
*history*, which is a different thing and is kept on purpose.

| Document | Why a reader might call it stale | Why it stays, unarchived and unedited |
|---|---|---|
| [Dead-code inventory](dead-code-inventory.md) | It is a *proposal* — a candidate list — and the work it proposed is finished, so the removal record appears to supersede it | It is the approval record: the artefact a human signed off before anything was deleted. The removal record cites it row by row and is unreadable without it. Archiving the proposal would leave the disposition with nothing to be a disposition *of* |
| [Dead-code removal record](dead-code-removal.md) | Describes a completed one-off sweep | It is the answer to "why is this gone?", which is the question a `git log` search answers slowly and badly. It also records the one candidate whose evidence in the inventory was **wrong** — a correction that only survives while both documents do |
| [What the dead-code sweep could not decide](dead-code-undecidable.md) | Reads as an unfinished to-do list | It is a register of *open* questions, not stale answers. Its six blind-spot classes are the reason `BlockReason.powerLow` is still in both ports, and re-deriving them costs more than keeping them |
| [The verification record](verification-record.md) | Its subject is a failure at tasklist `80`, long closed | The rule it states is live and enforced ([`CLAUDE.md` §3](../../CLAUDE.md)). The failure is what makes the rule legible; the rule without the cost reads as pedantry |
| [Environment verification matrix](environment-matrix.md) and [Environmental claim evidence](environment-evidence.md) | They overlap, and all 40 matrix cells have read `NOT YET VERIFIED` since 2026-08-20 | Neither supersedes the other: the matrix is per-cell, the evidence file is per-claim, and [`ROADMAP.md` phase 4](../../ROADMAP.md) is the plan to close them. A ledger of unmet obligations is not stale because the obligations are unmet — that is the ledger working. Both **were** corrected in this pass (§3); the duplicated closing procedure now has one home in the matrix |
| [iOS host integration](../guides/ios-host-integration.md) | Shortest doc in the tree, banner-dated 2026-08-19, the oldest in the repository | Every `AmphoraUploader` signature in it was read against `ios/Sources/Amphora/AmphoraUploader.swift` during US-2 and matched. An old date on a correct document is not a defect, and re-stamping it to look fresh would destroy the only signal a reader has |
| The two named-but-unwritten ADRs in [`docs/README.md`](../README.md#decisions) | They are cited and do not exist | They are *declared outstanding* in italics, not linked as though they were there. A declared gap is the honest form; deleting the mention would lose the fact that the decision was made and never written down |

## 3. What this pass changed

| Story | Change |
|---|---|
| US-1 | Structural: one missing banner, two unindexed documents, one directory outside the standard's seven (`android/BUILD.md` → [`reference/android-build.md`](android-build.md)) |
| US-2 | Content: 10 drifted claims across 8 reference documents, including the **normative** [state machine](state-machine.md) §3, whose event list named four things no port implements. Three facts stated twice and *disagreeing* were reduced to one home each |
| US-3 | [Environmental claim evidence](environment-evidence.md) and [the matrix](environment-matrix.md) — the two documents US-2 did not read — plus this record |

Measured after the last edit, over the 22 tracked markdown files outside `.chief/`: **0 dead file
links, 0 dead anchors, 22/22 banner-stamped, every document linked from
[`docs/README.md`](../README.md)**.

## 4. What this sweep did NOT verify

**Documentation correctness is not machine-checkable in general, and none of the above should be read
as a claim that these documents are now true.** What can be said is narrower and is worth saying
precisely:

- **Only the mechanical properties were swept exhaustively.** Links, anchors, banners, index
  coverage, and every backticked path and identifier resolving to something that exists. Those
  sweeps found **almost nothing** — the tree was already clean by every automated measure. Every
  substantive defect in this tasklist was semantic, found by reading a document against a type
  declaration. A future green link-check says nothing about whether this happened again.
- **The reading was one-directional, and that direction has a known blind spot.** Each claim in a
  document was checked to be true of the code. The reverse — behaviour the code implements that no
  document mentions — was not swept, so an *omission* would have survived this pass intact. The
  state-machine transition table is the concrete case: every row in it exists in both ports; whether
  the ports have rows it lacks was not established.
- **The conformance fixture is not a check on the prose.** `Tests/Conformance/vectors.json` encodes
  the ports' behaviour, so the normative specification can be wrong while all 40 vectors pass. That
  is exactly what had happened. Nothing in this pass changes that; a green suite still does not
  defend [`state-machine.md`](state-machine.md).
- **No integration harness was run.** Both are opt-in on `TUSD_ENDPOINT`, and Docker was not
  exercised here. The evidence cells in [Environmental claim evidence](environment-evidence.md) were
  read off the harness *source*, not off an execution of it.
- **Nothing Android-specific was verified locally.** There is no JDK on `PATH` on the authoring
  machine, so `Gradle build` reports `SKIPPED` in every run of `.chief/verify.sh` behind this
  tasklist. Per [`CLAUDE.md` §3](../../CLAUDE.md) that is **not** a pass. No Kotlin was changed by
  any of the three stories, so the skip conceals nothing about them — but the Kotlin *claims* in the
  corrected documents rest on reading the source, not on a build.
- **No verdict was upgraded.** All 40 device-matrix cells still read
  `NOT YET VERIFIED — physical device`, and this pass moved none of them. Correcting a document's
  description of its evidence is not the same as acquiring evidence.
- **The banner dates are now less informative than they look.** Thirteen files were re-stamped
  `2026-09-03` by this tasklist. A reader cannot tell from the banner alone whether a file was
  substantively re-derived or lightly touched; the `## Corrections` section is the honest signal, and
  a file without one was not corrected in this pass.

## Corrections

_None yet. When this record is found to have drifted, the correction goes here — dated, naming the
tasklist, saying what this file said and what the tree says._
