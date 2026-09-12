plugins {
    id("com.android.library") version "8.6.1" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
    id("org.jetbrains.kotlin.kapt") version "2.0.21" apply false
    // Pinned to the SAME version as room-runtime / room-compiler in android/build.gradle.kts.
    // The plugin's whole job is to hand the annotation processor `room.internal.schemaInput`
    // and `room.internal.schemaOutput`, and a plugin from a different release than the
    // processor reading those options is a configuration nobody tests.
    id("androidx.room") version "2.6.1" apply false
}
