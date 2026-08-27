# The verification record — what may be marked passing

> **Status:** Live · **Updated:** 2026-08-27 · **Owner:** Amphora

## The rule

**A story may not be marked passing on the strength of work that its own notes record as not
having run.**

If the note says *attempted*, *unavailable*, *could not*, *would have*, *skipped*, or *locally
absent*, the flag is `false`. There is no exception for "the code is obviously right", for "only
the toolchain was missing", or for "it is the machine's fault, not the branch's". Those are all
true statements about **why** it did not run, and none of them is evidence that it does.

This is not a style preference. It is the difference between two claims that a two-valued flag
cannot tell apart:

| Claim | What it licenses |
| --- | --- |
| **It ran and passed.** | Building on it. Citing it. Closing the question. |
| **It did not run.** | Nothing. The question is still open, and now it looks closed. |

A `false` flag on unrun work is honest and cheap — the next iteration picks the story up. A `true`
flag on unrun work is the expensive one, because it is indistinguishable from real evidence at
every point downstream, and its cost is paid by whoever cites it.

## What it cost here

`tasks/chief/completed/80-integration-against-tusd.json` shipped a story titled *"Both platforms
complete an upload against a real tusd instance"* with `passes: true`, and its own note said:

> Live Docker run was attempted but the local Docker daemon was unavailable.

and, on the resume story:

> Live Docker resume was attempted but the local Docker daemon was unavailable; Android Gradle was
> unavailable locally.

The notes were honest. The flags were not, and the flags are what anything downstream reads. That
record survived a merge to `main` at `c201ddf` and stood for a week as the repository's evidence
that bytes had moved. They had not; nothing in this repository had ever crossed a wire.

Two further facts only surfaced once the work was actually done, and both are what an unrun gate
reliably hides:

- The environment `80` shipped **could not have run at all.** Its MinIO image pins had been
  withdrawn from Docker Hub, so `compose up` failed on every machine on earth, not just the one
  without a daemon.
- Every `curl -X HEAD` in the harness hangs and exits `18`, because HEAD sends no body for curl to
  wait for. A single execution would have caught it. There had never been one.

An unrun check does not merely fail to prove its subject. It also fails to prove **itself**, and it
accumulates defects at exactly the rate of code nobody runs.

The record was corrected on 2026-08-27 by tasklist `120-real-wire-reverified`: both flags are now
`false`, the original notes are kept verbatim as the evidence, and a `correction` field beside each
records what `80` did build (the path), what it did not do (exercise it), and where the real
verification landed. **Correcting a merged record is uncomfortable and it is the cheaper half of
the trade** — the alternative is a repository whose central claim is documented as proven when it
is not.

## The vocabulary, in all three places it appears

The repository refuses to collapse "did not run" into "passed" at every layer, and the three
spellings are deliberately the same shape:

| Layer | Ran and passed | Ran and failed | Never ran |
| --- | --- | --- | --- |
| `.chief/verify.sh` | `PASS` | `FAIL` | `SKIPPED` — *UNVERIFIED, not passed* |
| `integration/tusd/*.sh` (`lib.sh`) | exit `0` | exit `1` | exit `77` — *SKIP … proved nothing* |
| A story's `passes` + `notes` | `true`, with the observed output quoted | `false` | `false`, and the criterion reported `UNVERIFIABLE HERE` |

Each layer also has a switch that makes the third column red where a skip would be dishonest —
`AMPHORA_VERIFY_STRICT=1` (set automatically by `CI=true`) and `AMPHORA_REQUIRE_DOCKER=1`. Use it
in any run whose *purpose* is to produce evidence. See
[Continuous integration § A skipped check is not a passing check](continuous-integration.md#a-skipped-check-is-not-a-passing-check)
and [the tusd guide's exit-code table](../guides/tusd-integration.md).

## What a passing note has to contain

An observation, not an intention. Quote the number or the line the run printed:

- **Good** — `run.sh exit 0: "3 MiB create/head/patch/terminate passed"`; `46 passed, 0 failed`;
  `CI run 33044191974, job android: success`.
- **Not a note** — "tests added", "should pass in CI", "compiles clean locally so the Android build
  will be fine", "verified by inspection".

Two rules that follow from the same principle:

- **A run id beats an adjective.** "CI is wired" is not evidence; a run id and its conclusion are.
- **A green check on machine A does not predict machine B.** The Kotlin port can only be exercised
  in CI (no JDK or Android SDK locally); the Swift real-wire harness can only be exercised locally
  (GitHub's macOS runners have no Docker daemon); and `verify.sh` is knowingly not identical to CI.
  Say which machine produced the line you are quoting.

## When you genuinely cannot run it

Say so, in those words, and leave the flag `false`. `UNVERIFIABLE HERE` is a respectable outcome
and a useful one — it names a gap that someone can close. The environment ledgers already work this
way: [Environmental claim evidence](environment-evidence.md) keeps every device-dependent cell at
`NOT YET VERIFIED — physical device` rather than substituting a simulator result, and
[the environment matrix](environment-matrix.md) does the same. That discipline is the norm in this
repository; `80` was the exception, and this document exists so it stays one.
