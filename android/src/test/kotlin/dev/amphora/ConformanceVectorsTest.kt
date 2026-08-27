package dev.amphora

import dev.amphora.core.SeekableSource
import dev.amphora.core.UploadStateMachine
import dev.amphora.model.*
import dev.amphora.transport.RangeRequestBody
import okhttp3.MediaType.Companion.toMediaType
import okio.Buffer
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import java.io.File
import java.nio.file.Files

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
        const val EXPECTED_SCHEMA_VERSION = 2
        const val EXPECTED_VECTOR_COUNT = 40

        /**
         * `Enqueue` is the one event that creates a job rather than reducing one, so it has no
         * `reduce()` call to exercise and is counted instead of run. Asserting the count of these
         * closes the hole that a bare `continue` leaves: without it, a fixture whose rows had all
         * degenerated to `Enqueue` would skip all forty, reduce nothing, and still pass.
         */
        const val EXPECTED_UNREDUCED_COUNT = 1

        /**
         * The I6 rows: "no chunk temp file outlives a transport attempt". Counted for the same
         * reason as the transition rows — a section trimmed to one row must fail as "expected 3,
         * got 1" rather than pass as a full I6 run.
         */
        const val EXPECTED_I6_VECTOR_COUNT = 3
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

    /**
     * I6 is the design claim with the largest consequence and, until these rows, no check at all.
     * It is stated in README.md, in state-machine.md §4 and in this port's own [TusTransport] doc
     * comment; a port that quietly stages "just the remainder" satisfies every transition vector in
     * the fixture while taking peak extra storage from about zero to the size of the file, and
     * reintroduces the class of bug — the OS reclaiming a cache file mid-transfer — the whole
     * design exists to retire.
     *
     * The rows are shared with Swift; the observation is necessarily port-specific. Here it is what
     * [RangeRequestBody] streams to its sink: the bytes come straight out of the source file at the
     * resume offset, and nothing is written to disk. `ConformanceTests.swift` makes the equivalent
     * observation of what `NativeResumableTransport` hands the background session.
     */
    @Test
    fun sharedI6VectorsHoldForTheAndroidTransport() {
        val root = ConformanceVectors.load()
        val section = root.optJSONObject("transportInvariants")
            ?: throw AssertionError(
                "conformance vectors at ${ConformanceVectors.file()}: missing `transportInvariants` — " +
                    "dropping that section would silently drop the only check on the no-chunk-temp-files commitment",
            )
        val rows = section.optJSONArray("i6NoChunkTempFiles")
            ?: throw AssertionError(
                "conformance vectors at ${ConformanceVectors.file()}: missing `transportInvariants.i6NoChunkTempFiles`",
            )
        assertEquals(EXPECTED_I6_VECTOR_COUNT, rows.length(), "I6 vector count in ${ConformanceVectors.file()}")

        var checked = 0
        for (index in 0 until rows.length()) {
            runI6Vector(rows.getJSONObject(index))
            checked++
        }
        assertEquals(
            EXPECTED_I6_VECTOR_COUNT,
            checked,
            "I6 vectors actually executed — 'ran 0 vectors' is a failure, not a pass",
        )
    }

    private fun runI6Vector(row: JSONObject) {
        val id = row.getString("id")
        val sizeBytes = row.getLong("sizeBytes")
        val resumeFrom = row.getLong("resumeFrom")
        val expect = row.getJSONObject("expect")

        val scratch = Files.createTempDirectory("amphora-i6").toFile()
        // Point the JVM's temp directory at the scratch directory for the duration of the attempt.
        // A remainder file is written either beside the source or "somewhere temporary"; this makes
        // both land where the inventory below is looking.
        val previousTmp = System.getProperty("java.io.tmpdir")
        try {
            System.setProperty("java.io.tmpdir", scratch.absolutePath)

            val source = File(scratch, "source.bin")
            source.writeBytes(ByteArray(sizeBytes.toInt()) { (it % 251).toByte() })
            val expectedBytes = expect.getLong("bytesFromSource")

            val before = inventory(scratch)
            val streamed = Buffer()
            SeekableSource.fromFile(source).use { seekable ->
                val body = RangeRequestBody(
                    source = seekable,
                    offset = resumeFrom,
                    length = sizeBytes - resumeFrom,
                    contentType = "application/offset+octet-stream".toMediaType(),
                    deadlineMillis = Long.MAX_VALUE,
                    now = { 0L },
                    onProgress = {},
                )
                assertEquals(expectedBytes, body.contentLength(), "$id: declared Content-Length")
                body.writeTo(streamed)
                assertEquals(expectedBytes, body.bytesWritten, "$id: bytes read out of the source")
            }

            val created = inventory(scratch) - before
            assertEquals(
                expect.getInt("filesCreatedInWorkDir"),
                created.size,
                "$id: I6 violated — ${created.size} file(s) materialised during the attempt ($created). " +
                    "Byte ranges stream from the source; nothing is written to disk.",
            )
            assertTrue(
                !expect.getBoolean("stagesRemainder"),
                "$id: this fixture row expects a staged remainder, which no port here implements",
            )
            assertEquals(expectedBytes, streamed.size, "$id: bytes handed to the sink")
            // The bytes must be the source's own, at the resume offset — a body that streams the
            // right COUNT of the wrong bytes is a corrupt upload, not a passing vector.
            assertTrue(
                streamed.readByteArray().contentEquals(source.readBytes().copyOfRange(resumeFrom.toInt(), sizeBytes.toInt())),
                "$id: the streamed window is not source[$resumeFrom, $sizeBytes)",
            )
            assertEquals(sizeBytes, source.length(), "$id: the transport must not rewrite or truncate the source")
        } finally {
            System.setProperty("java.io.tmpdir", previousTmp)
            scratch.deleteRecursively()
        }
    }

    /** Every path under [directory], relative to it, so the diff names what appeared. */
    private fun inventory(directory: File): Set<String> =
        directory.walkTopDown()
            .filter { it != directory }
            .map { it.relativeTo(directory).path }
            .toSet()

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
