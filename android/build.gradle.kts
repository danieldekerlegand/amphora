plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.kapt")
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

kapt {
    arguments {
        // UploadDatabase declares exportSchema = true deliberately: migrations must move rows in
        // place, and that is unreviewable without the schema history. Room warns and exports
        // nothing unless it is told where to put them.
        arg("room.schemaLocation", "$projectDir/schemas")
    }
}

dependencies {
    implementation("androidx.annotation:annotation:1.8.2")
    implementation("androidx.core:core-ktx:1.13.1")
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
