# Android build requirements

> **Status:** Live · **Updated:** 2026-09-03 · **Owner:** Daniel DeKerlegand

_Moved here from `android/BUILD.md` on 2026-09-03. It was the one document in this tree that
lived outside `docs/` and was linked from nowhere — unreachable documentation that still greps
as current. Nothing referenced the old path, so no citation needed repointing._

Run the library build from the repository root with the **checked-in wrapper**:

```sh
./gradlew :android:assemble
./gradlew :android:testDebugUnitTest    # the Kotlin conformance vectors
```

**Not bare `gradle`.** The wrapper pins Gradle **8.10.2** by distribution URL *and* SHA-256
(`gradle/wrapper/gradle-wrapper.properties`); bare `gradle` uses whatever the machine or runner
image happens to ship, so a runner-image bump can change or break the build with no commit here.
The `android` CI job carries the same instruction as a comment and runs `./gradlew` for the same
reason, and it additionally runs `gradle/actions/wrapper-validation` so the committed
`gradle-wrapper.jar` cannot be quietly swapped.

The module requires **JDK 17** and the **Android SDK Platform 35** (Android 15), with the Android
Gradle Plugin's matching build tools installed. AGP 8.6.1 requires Gradle 8.7 or newer, which is
why the wrapper pin is 8.10.2 rather than the minimum. The authoring machine has no JDK and no
Android SDK, so `.chief/verify.sh` reports `SKIPPED Gradle build: no JDK on PATH` here and every
Android claim rests on CI — see [Continuous integration](continuous-integration.md#a-skipped-check-is-not-a-passing-check).

The library uses `minSdk 26` to retain the Android 8 API floor used by the
existing storage and network implementations, while `targetSdk 35` aligns the
module with Android 15's foreground-service behavior. The upload worker is
explicitly designed around Android 15's `dataSync` foreground-service budget of
6 hours per 24 hours, so targeting 35 makes that bounded-worker contract compile
and validate against the platform behavior it is intended to handle.

Read off `android/build.gradle.kts` and the root `build.gradle.kts` on 2026-09-03: `compileSdk 35`,
`minSdk 26`, `targetSdk 35`, `JavaVersion.VERSION_17`, AGP 8.6.1, Kotlin 2.0.21.

## Corrections

**2026-09-03, tasklist `901-docs-tell-the-truth`.** This document told the reader to run
`gradle :android:assemble`. That command is not what builds this module anywhere: the repository
carries a checked-in wrapper, `gradle/wrapper/gradle-wrapper.properties` opens with a comment
saying bare `gradle` is not reproducible (the runner image shipped 9.7.0 on 2026-08-27), and
`.github/workflows/ci.yml` carries the same instruction beside its own `./gradlew` invocation. The
document was the only place in the tree still recommending the unreproducible form. It also said
"Gradle 8.7 or newer is required" without naming the version actually pinned; both facts are now
stated together, since 8.7 is the AGP floor and 8.10.2 is what any build here will use.
