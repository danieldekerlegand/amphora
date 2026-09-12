// SPDX-License-Identifier: MIT

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.kapt")
    id("androidx.room")
}

android {
    namespace = "dev.amphora"
    compileSdk = 35

    defaultConfig {
        minSdk = 26
        targetSdk = 35
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        buildConfig = false
    }

    testOptions {
        unitTests {
            // The mockable android.jar throws `RuntimeException("Stub!")` from every framework
            // method. StorageGovernorTest drives a real ContextWrapper subclass, so without this
            // the JVM unit tests fail on the framework rather than on the code under test.
            isReturnDefaultValues = true

            all {
                // Both ports read the SAME Tests/Conformance/vectors.json — one file, no
                // per-platform copy, because a second copy would reintroduce exactly the drift
                // the vectors exist to catch. Tell the tests where the repository root is
                // instead of moving the runner's working directory to it: the working directory
                // is a property of whoever launched the build, and making the suite depend on it
                // is what let `swift run AmphoraPathTests` from ios/ die with a file-not-found
                // error that read as a broken machine. ConformanceVectors.file() falls back to
                // walking up from the working directory if this property ever goes missing.
                it.systemProperty("amphora.repoRoot", rootDir.absolutePath)

                // A per-run temp directory instead of the machine's shared /tmp. TusdIntegrationTest
                // measures peak extra disk under java.io.tmpdir to check invariant I6 (the transport
                // stages no chunk file), and on a shared /tmp that measurement would be reading other
                // processes' noise. It is also where the `kotlin / I6 drift` control in
                // Tests/Conformance/drift-control.sh writes its counterfactual chunk file.
                val testTmp = layout.buildDirectory.dir("test-tmp").get().asFile
                it.systemProperty("java.io.tmpdir", testTmp.absolutePath)
                it.doFirst { testTmp.mkdirs() }

                // The real-wire test is opt-in on TUSD_ENDPOINT and must be able to tell "no server
                // here" from "the server said no". Forwarded explicitly rather than relied on being
                // inherited, and declared through `providers` so Gradle treats the value as a build
                // input instead of silently caching a task that ran with a different one.
                providers.environmentVariable("TUSD_ENDPOINT").orNull
                    ?.let { endpoint -> it.environment("TUSD_ENDPOINT", endpoint) }
                providers.environmentVariable("AMPHORA_REQUIRE_DOCKER").orNull
                    ?.let { require -> it.environment("AMPHORA_REQUIRE_DOCKER", require) }

                // Print per-test results. `BUILD SUCCESSFUL` on a task that ran zero tests looks
                // exactly like one that ran forty, and this repo has already merged three stories
                // on that confusion.
                it.testLogging {
                    events("passed", "skipped", "failed")
                    showStandardStreams = false
                }
            }
        }
    }
}

// UploadDatabase declares exportSchema = true deliberately: migrations must move rows in place,
// and that is unreviewable without the schema history. Room warns and exports nothing unless it
// is told where to put them.
//
// This is the Room Gradle Plugin's job, NOT `kapt { arguments { arg("room.schemaLocation", ...) } }`
// — and the difference is a build failure this job actually hit. Under the raw option, Room reads
// `schemaInFolderPath` and `schemaOutFolderPath` from the SAME value (Context.kt:150-178 of Room
// 2.6.1), so `:android:kaptDebugKotlin` and `:android:kaptReleaseKotlin` — which Gradle starts
// concurrently; 02:51:02.2888336Z and 02:51:02.2893492Z in run 34556064209 — both read and both
// truncate ONE file, `schemas/dev.amphora.store.UploadDatabase/1.json`. `Database.exportSchema`
// serializes through `FileOutputStream(file, false)`, so that file is zero bytes for the width of
// a write, and the other variant deserializing it there gets Gson's null and
// `IllegalStateException("Empty schema file")` — SchemaBundle.kt:69 <- Database.kt:110, the exact
// frames of run 33044503283. The plugin gives each variant task its own output directory under
// `build/intermediates/room/schemas/<task>`, leaves this directory read-only to the processor, and
// copies in afterwards from a task both kapt tasks are `finalizedBy`. Nothing shares a write
// target, so there is no window to lose.
//
// The two mechanisms are also mutually exclusive by Room's own check: setting both makes
// `room.internal.schemaOutput` and `room.schemaLocation` visible at once, which Room reports as
// INVALID_GRADLE_PLUGIN_AND_SCHEMA_LOCATION_OPTION — an error, not a warning.
//
// kapt's `Kapt currently doesn't support language version 2.0+. Falling back to 1.9.` warning is
// real and still here. Moving to KSP is a `replace` tasklist, not this fix.
room {
    schemaDirectory("$projectDir/schemas")
}

dependencies {
    implementation("androidx.annotation:annotation:1.8.2")
    implementation("androidx.room:room-runtime:2.6.1")
    // UploadDao's queries are `suspend`/`Flow`. Room's compiler rejects those outright without
    // room-ktx — the first real Gradle build (CI run 33038526156) failed here with
    // "To use Coroutine features, you must add `ktx` artifact from Room as a dependency".
    implementation("androidx.room:room-ktx:2.6.1")
    implementation("androidx.work:work-runtime-ktx:2.9.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    kapt("androidx.room:room-compiler:2.6.1")
    testImplementation(kotlin("test"))
    testImplementation("junit:junit:4.13.2")
    // org.json ships in android.jar as stubs only; ConformanceVectorsTest parses the shared
    // vector file with it, so the unit tests need a real implementation on the classpath.
    testImplementation("org.json:json:20240303")
}
