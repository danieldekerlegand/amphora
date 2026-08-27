# Continuous integration

> **Status:** Live · **Updated:** 2026-08-26 · **Owner:** Amphora

Until 2026-08-26 this repository had **no git remote**. `.github/workflows/ci.yml` had existed
for weeks and had never executed on any machine, which made every Android claim in this
repository *unfalsifiable* rather than false: the Kotlin port had never been compiled by
anything, and the Kotlin half of the conformance vectors had never been run. This document
records the decisions that ended that, so they are not quietly undone.

## Remote

`origin` → <https://github.com/danieldekerlegand/amphora>

## Visibility: public, deliberately

GitHub Actions minutes are **free for public repositories and billed for private ones**. This
account's private-repository Actions are currently blocked outright:

> The job was not started because recent account payments have failed or your spending limit
> needs to be increased.

A private `amphora` would therefore have produced a workflow that *cannot start* — the same
un-runnable gate this work exists to remove, with a green-looking configuration in front of it.
The repository is public so that CI can actually run.

What was checked before publishing: the tree carries no credentials. The only secret-shaped
strings are the placeholder MinIO/tusd credentials in `integration/tusd/docker-compose.yml`,
which exist solely to bring up a throwaway local container.

**If this repository is ever made private, CI stops being a gate** until billing is confirmed
working — a private run that never starts reports no failure, and "no failure" is not a pass.
Say so out loud at that point rather than leaving the workflow file to imply coverage.

## Trigger: `push` on `main` and `chief/**`

Work is not delivered here by pull request. Chief merges a finished tasklist branch into `main`
locally with `--no-ff` and pushes `main`; no PR is ever opened. A `pull_request`-only trigger
would consequently never fire — the failure mode observed in the sibling repository `vita`,
whose workflow went its whole life without a single run.

So the trigger is:

| Event | Why |
|---|---|
| `push` to `main` | The path every merged tasklist actually takes. |
| `push` to `chief/**` | Builds a tasklist branch *before* it is merged, not only after. |
| `pull_request` | Retained for humans who do open one. Not the primary path. |
| `workflow_dispatch` | Forces a run without inventing a commit. |

The reasoning is repeated as a comment at the top of `.github/workflows/ci.yml`, because that is
where a future reader will meet it and be tempted to "tidy" it back.

## Reading a run

```sh
gh run list --limit 5
gh run view <run-id>
```

A run's **conclusion** is the claim. "CI is wired" is not evidence; a run id and its conclusion
are. Related: [Environmental claim evidence](environment-evidence.md).
