package dev.amphora

import dev.amphora.core.UploadStateMachine
import dev.amphora.model.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import java.io.File

/**
 * Why the vectors are not loaded by a relative path.
 *
 * `Tests/Conformance/vectors.json` is the ONE file both ports read, and its whole job is to stop
 * the Swift and Kotlin state machines drifting apart. Reaching it as a repo-root-relative path
 * made the runner's working directory a hidden precondition: Gradle runs unit tests from
 * `android/`, where that path does not resolve, and the previous fix was to move the runner's
 * working directory instead of anchoring the lookup. `android/build.gradle.kts` now injects
 * `amphora.repoRoot`; if that is ever absent the search walks up from the working directory
 * until it finds the fixture. `ios/Tests/AmphoraTests/ConformanceTests.swift` anchors the same
 * way (from `#filePath`), against the same single file — a second copy of the fixture would
 * reintroduce exactly the drift the vectors exist to catch.
 */
internal object ConformanceVectors {
    const val RELATIVE_PATH = "Tests/Conformance/vectors.json"

    /** Locate the fixture without consulting — or trusting — the caller's working directory. */
    fun file(): File {
        val searched = mutableListOf<File>()

        System.getProperty("amphora.repoRoot")?.takeIf { it.isNotBlank() }?.let { root ->
            val candidate = File(root, RELATIVE_PATH)
            searched += candidate
            if (candidate.isFile) return candidate
        }

        var directory: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (directory != null) {
            val candidate = File(directory, RELATIVE_PATH)
            searched += candidate
            if (candidate.isFile) return candidate
            directory = directory.parentFile
        }

        throw AssertionError(
            "conformance vectors not found. Looked for $RELATIVE_PATH under the amphora.repoRoot " +
                "system property and every ancestor of ${System.getProperty("user.dir")}:\n" +
                searched.joinToString("\n") { "  - $it" },
        )
    }

    /**
     * Read and shape-check the fixture. Every failure is a legible assertion, never a silent
     * pass: an absent or half-written fixture reporting green is the failure mode these vectors
     * exist to rule out.
     */
    fun load(): JSONObject {
        val file = file()
        val text = try {
            file.readText()
        } catch (error: Exception) {
            throw AssertionError("conformance vectors at $file could not be read: $error", error)
        }
        val root = try {
            JSONObject(text)
        } catch (error: Exception) {
            throw AssertionError("conformance vectors at $file are malformed: $error", error)
        }
        assertTrue(root.has("schemaVersion"), "conformance vectors at $file: missing schemaVersion")
        val entries = root.optJSONArray("vectors")
            ?: throw AssertionError("conformance vectors at $file: missing array `vectors`")
        assertTrue(
            entries.length() > 0,
            "conformance vectors at $file: zero vectors is a failure, not a pass",
        )
        return root
    }
}

class ConformanceVectorsTest {
    private companion object {
        /**
         * The fixture's shape is asserted, never discovered.
         *
         * A test runner that discovers zero tests is a failure, not a pass, and the same holds
         * for a vector suite: a truncated or half-written `vectors.json` must go red rather than
         * quietly report a full run over a fraction of the rows. These three numbers are the
         * independent witness — they live in the test, not in the fixture, so a fixture rewritten
         * by a generator cannot rewrite its own expectations along with it. Adding a vector is
         * meant to require touching both ports; that friction is the point.
         */
        const val EXPECTED_SCHEMA_VERSION = 1
        const val EXPECTED_VECTOR_COUNT = 40

        /**
         * `Enqueue` is the one event that creates a job rather than reducing one, so it has no
         * `reduce()` call to exercise and is counted instead of run. Asserting the count of these
         * closes the hole that a bare `continue` leaves: without it, a fixture whose rows had all
         * degenerated to `Enqueue` would skip all forty, reduce nothing, and still pass.
         */
        const val EXPECTED_UNREDUCED_COUNT = 1
    }

    @Test
    fun sharedVectorsMatchAndroidPort() {
        val root = ConformanceVectors.load()
        assertEquals(EXPECTED_SCHEMA_VERSION, root.getInt("schemaVersion"), "vectors schemaVersion")
        val entries = root.getJSONArray("vectors")
        // Assert the count BEFORE reducing anything. A fixture truncated to eighteen rows should
        // fail as "expected 40 vectors, got 18", not as whichever unrelated assertion those
        // eighteen happen to trip over first.
        assertEquals(
            EXPECTED_VECTOR_COUNT,
            entries.length(),
            "vector count in ${ConformanceVectors.file()}",
        )

        var reduced = 0
        var unreduced = 0
        for (index in 0 until entries.length()) {
            val vector = entries.getJSONObject(index)
            val eventJson = vector.getJSONObject("event")
            if (eventJson.getString("type") == "Enqueue") {
                unreduced++
                continue
            }
            reduced++
            val transition = UploadStateMachine.reduce(job(vector.getJSONObject("given")), event(eventJson), 10L)
            val expect = vector.getJSONObject("expect")
            val id = vector.getString("id")
            assertEquals(UploadState.valueOf(expect.getString("state")), transition.job.state, id)
            if (expect.has("serverOffset")) assertEquals(expect.getLong("serverOffset"), transition.job.serverOffset, id)
            if (expect.has("bytesTransferred")) assertEquals(expect.getLong("bytesTransferred"), transition.job.bytesTransferred, id)
            if (expect.has("attemptCount")) assertEquals(expect.getInt("attemptCount"), transition.job.attemptCount, id)
            if (expect.optBoolean("terminateRemote")) assertTrue(transition.effects.any { it is Effect.TerminateRemote }, id)
            if (expect.optJSONArray("requiredEffects")?.toString()?.contains("HEAD_BEFORE_RESUME") == true) assertTrue(transition.effects.contains(Effect.HeadBeforeResume), id)
        }

        assertEquals(
            EXPECTED_UNREDUCED_COUNT,
            unreduced,
            "vectors skipped as non-reducing (Enqueue) — a growing count means rows stopped being exercised",
        )
        assertEquals(
            EXPECTED_VECTOR_COUNT - EXPECTED_UNREDUCED_COUNT,
            reduced,
            "vectors actually put through UploadStateMachine.reduce — 'ran 0 vectors' is a failure, not a pass",
        )
    }

    private fun job(given: JSONObject): UploadJob = UploadJob(
        id = "vector", sourceKind = SourceKind.FILE, sourceUri = "vector", sizeBytes = given.optLong("sizeBytes", 1000),
        contentType = "application/octet-stream", fingerprint = "vector", endpoint = "https://example.test",
        uploadUrl = given.optString("uploadUrl", null), state = UploadState.valueOf(given.optString("state", "PENDING")),
        blockReason = given.optString("blockReason", "").takeIf { it.isNotEmpty() }?.let { BlockReason.valueOf(it) },
        serverOffset = given.optLong("serverOffset", 0), attemptCount = given.optInt("attemptCount", 0),
        remoteTerminated = given.optBoolean("remoteTerminated", true), createdAt = 1, updatedAt = 1,
    )

    private fun event(value: JSONObject): UploadEvent = when (value.getString("type")) {
        "Schedule" -> UploadEvent.Schedule
        "SourceResolved" -> UploadEvent.SourceResolved(value.getLong("sizeBytes"), value.getString("fingerprint"), value.optString("stagedPath", null))
        "SourceMissing" -> UploadEvent.SourceMissing
        "SpaceDenied" -> UploadEvent.SpaceDenied(value.getLong("needed"))
        "RemoteCreated" -> UploadEvent.RemoteCreated(value.getString("uploadUrl"), value.optLong("expiresAt").takeIf { value.has("expiresAt") && !value.isNull("expiresAt") })
        "OffsetAdvanced" -> UploadEvent.OffsetAdvanced(value.getLong("serverOffset"))
        "TransportComplete" -> UploadEvent.TransportComplete
        "ServerAck" -> UploadEvent.ServerAck
        "TransportError" -> UploadEvent.TransportError(ErrorClass.valueOf(value.getString("errorClass")), value.optString("detail", null))
        "Blocked" -> UploadEvent.Blocked(BlockReason.valueOf(value.getString("blockReason")))
        "Pause" -> UploadEvent.Pause
        "Gone" -> UploadEvent.Gone
        "OffsetDiverged" -> UploadEvent.OffsetDiverged(value.getLong("serverOffset"))
        "DeadlineReached" -> UploadEvent.DeadlineReached
        "AttemptsExhausted" -> UploadEvent.AttemptsExhausted
        "GateCleared" -> UploadEvent.GateCleared
        "Resume" -> UploadEvent.Resume
        "Retry" -> UploadEvent.Retry
        "Cancel" -> UploadEvent.Cancel
        "ProcessStart" -> UploadEvent.ProcessStart
        else -> error("unknown vector event")
    }
}
