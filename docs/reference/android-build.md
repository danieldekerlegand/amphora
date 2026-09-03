# Android build requirements

> **Status:** Draft · **Updated:** 2026-09-03 · **Owner:** Daniel DeKerlegand

_Moved here from `android/BUILD.md` on 2026-09-03. It was the one document in this tree that
lived outside `docs/` and was linked from nowhere — unreachable documentation that still greps
as current. Nothing referenced the old path, so no citation needed repointing._

Run the library build from the repository root with:

```sh
gradle :android:assemble
```

The module requires **JDK 17** and the **Android SDK Platform 35** (Android 15),
with the Android Gradle Plugin's matching build tools installed. Gradle 8.7 or
newer is required by Android Gradle Plugin 8.6.1. The authoring machine does not
have a JDK or Android SDK installed; CI and Android development machines must
provide these prerequisites.

The library uses `minSdk 26` to retain the Android 8 API floor used by the
existing storage and network implementations, while `targetSdk 35` aligns the
module with Android 15's foreground-service behavior. The upload worker is
explicitly designed around Android 15's `dataSync` foreground-service budget of
6 hours per 24 hours, so targeting 35 makes that bounded-worker contract compile
and validate against the platform behavior it is intended to handle.
