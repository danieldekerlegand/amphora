# Licensing — the choice, and what it was checked against

> **Status:** Live · **Updated:** 2026-09-03 · **Owner:** Daniel DeKerlegand

Amphora is **MIT**. The licence text is at [`LICENSE`](../../LICENSE).

This document records *why* that was chosen and *what was verified* before choosing it, because a
licence picked by default is indistinguishable in the tree from one picked deliberately, and only
one of them survives contact with a legal review.

## Why MIT

This is a client library whose entire purpose is to be embedded in somebody else's application.
That single fact does most of the deciding:

- **The consumer is a host app, and often a closed-source one.** A reciprocal licence — GPL, or
  LGPL's relinking obligation, or MPL's per-file source disclosure — would make adoption a legal
  question for every prospective host. For a library competing against `tus-js-client` (MIT),
  TUSKit (MIT), and the AWS SDKs (Apache-2.0), any such term is simply disqualifying. The
  [README's own framing](../../README.md) is that off-the-shelf coverage is uneven and this fills
  the gaps; a licence that narrows who may adopt it defeats the premise.
- **MIT over Apache-2.0.** Apache-2.0's express patent grant and its NOTICE mechanics are the usual
  reason to prefer it. Neither earns its keep here: this repository deliberately **re-specifies no
  protocol and invents no algorithm** — it implements `draft-ietf-httpbis-resumable-upload` as
  published — so there is no patentable surface for a grant to cover. What remains is the ecosystem
  argument, and the mobile/JS ecosystem this ships into is overwhelmingly MIT.
- **It matches what the repository already claimed.** `packages/react-native/package.json` has
  declared `"license": "MIT"` since the package was created, with no `LICENSE` file behind it. That
  is a promise the tree could not keep: npm would render "MIT" on the package page while the
  repository granted nothing. Adding this file makes the existing declaration true rather than
  introducing a new position.

**No copyleft obligation reaches this code**, and that was checked rather than assumed. The
evidence is below.

## What was verified

Checked 2026-08-27. Each row names where the verdict was read from, so it can be re-checked rather
than trusted.

### Adopted, not vendored

Nothing in this table is linked into the shipped library. They matter to the licence question only
insofar as an obligation might travel inward, and none does.

| Component | Licence | Read from | Why nothing travels inward |
| --- | --- | --- | --- |
| `draft-ietf-httpbis-resumable-upload` | IETF Trust Legal Provisions | The draft | A specification is implemented, not copied. No spec text is vendored here. |
| tusd v2.4.0 (server) | MIT | `tus/tusd` `LICENSE.txt` | A separate server process reached over HTTP. Pinned by digest in `integration/tusd/docker-compose.yml`. |
| `tus-js-client` | MIT | `tus/tus-js-client` `LICENSE` | **Not a dependency of this repository at all** — it appears only in prose. This repo ships no web transfer code. |
| TUSKit | MIT | — | **Not a dependency.** `ios/Package.swift` declares no external packages, and `TUSKitTransport` does not import TUSKit; the name records the role, not a linkage. |
| MinIO (test harness) | **AGPL-3.0** | `minio/minio` `LICENSE` | The one copyleft component anywhere near this tree. It is an unmodified upstream container in the integration harness, run as a separate process and never distributed with or linked into Amphora, so AGPL-3.0 §13 is not engaged. Worth stating explicitly precisely *because* a reader who greps for copyleft will find it. |

### Actually depended on

| Scope | Dependency | Licence | Read from |
| --- | --- | --- | --- |
| iOS runtime | *(none)* | — | `ios/Package.swift` declares zero external packages; only the system `sqlite3` is linked. |
| Android runtime | `androidx.annotation`, `androidx.room:room-runtime`, `androidx.room:room-ktx`, `androidx.work:work-runtime-ktx` | Apache-2.0 | POM `<licenses>` on Google Maven, read against the `dependencies` block of `android/build.gradle.kts` |
| Android runtime | `kotlinx-coroutines-android` 1.8.1, `okhttp` 4.12.0 | Apache-2.0 | POM `<licenses>` on Maven Central |
| Android build-time | `androidx.room:room-compiler` (kapt) | Apache-2.0; BSD | POM `<licenses>`. Annotation processor — runs at build time, ships nothing. |
| Android test-only | `junit` 4.13.2 | EPL-1.0 | POM `<licenses>`. **Weak copyleft, and the only reason it is harmless is that it is `testImplementation`** — not on any consumer's classpath. |
| Android test-only | `org.json:json` 20240303 | Public Domain | POM `<licenses>`. The historical "Good, not Evil" JSON License clause is *not* present in this version — checked, not assumed. |
| React Native | `react-native` (peer, `>=0.76.0`) | MIT | `package-lock.json` |
| React Native dev tree | 498 transitive packages | 426 MIT · 38 ISC · 12 BSD-3 · 6 BSD-2 · 11 Apache-2.0 · 2 0BSD · 1 CC-BY-4.0 (`caniuse-lite`, data) · 1 `(MIT OR CC0-1.0)` · 1 `(BSD-3-Clause OR GPL-2.0)` (`node-forge`, dual — the BSD option is taken) · 1 "BSD" | `package-lock.json` `license` fields |

**Zero unilateral copyleft in the dependency graph.** The published npm package declares no runtime
`dependencies` at all — only a `react-native` peer — so a consumer installing `@amphora/react-native`
inherits nothing from the dev tree above.

## File-level convention

**Amphora does not put a licence header on every source file.** The convention is:

1. **`LICENSE` at the repository root is authoritative** for every file in the tree. There is no
   file, directory, or port under a different licence, and if one is ever added it must say so at
   its own root and be listed here.
2. **Each distributable manifest carries the SPDX identifier `MIT`**, because that is what package
   registries, SBOM generators, and licence scanners actually read:
   - `packages/react-native/package.json` — the `"license"` field.
   - `ios/Package.swift` and `android/build.gradle.kts` — an `SPDX-License-Identifier: MIT` comment,
     since SwiftPM and Gradle have no equivalent field for a non-published package.
3. **New source files inherit the root licence silently.** Do not add per-file headers.

Point 3 is the deliberate part. Per-file headers on 5,907 lines across two ports buy nothing that
the root `LICENSE` and the manifest identifiers do not already provide, while adding a line to every
file that must be kept consistent and that will eventually drift — a repository with headers on 80%
of its files is *less* legible about its licence than one with none. The place a machine looks is
the manifest, and the manifests are covered.

## Open

- **The copyright holder is an individual.** If this repository is ever transferred to an
  organisation, the holder line in `LICENSE` needs updating, and that is the only place it appears.
- **The project name is still a placeholder** (see [`ROADMAP.md`](../../ROADMAP.md)). A rename does
  not affect the licence, but it does affect the npm scope `@amphora/react-native`.

## Corrections

**2026-09-03, tasklist `901-docs-tell-the-truth`.** Two figures in this document were read against
the tree and did not survive it.

- **`androidx.core:core-ktx` was listed as a declared Android runtime dependency. It is not one.**
  The declaration was deleted in `6d16ac7` by the dead-code sweep (`dead-code-inventory.md` §1.4)
  because nothing in the module imports `androidx.core`. It is still on the resolved classpath as a
  transitive dependency of `work-runtime-ktx`, and still Apache-2.0, so **the licence conclusion
  does not change** — but the audit's claim to have been read off `android/build.gradle.kts` did,
  and an audit that names a dependency the manifest no longer declares is one nobody can reproduce.
  The row now names the four `androidx` artifacts the `dependencies` block actually declares.
- **The line count was `5,951`; it is now `5,907`.** Re-measured with
  `git ls-files 'ios/**/*.swift' 'android/**/*.kt' | xargs wc -l`. The argument does not turn on the
  number, but a number nobody can reproduce is worse than no number, so the command is now stated
  beside it.
