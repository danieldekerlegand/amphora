package dev.amphora

import dev.amphora.core.SeekableSource
import dev.amphora.transport.TusTransport
import dev.amphora.transport.WireDialect
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * The Kotlin port against a real tusd, across a real interruption, with disk measured.
 *
 * This is the Kotlin half of `integration/tusd/swift-wire.sh`. It is opt-in via `TUSD_ENDPOINT`
 * and is driven by the `android` CI job, which stands the Compose stack up first — no JDK exists
 * on the machines these stories are written on, so CI is the only place this has ever run.
 *
 * Three things it does that the previous version did not:
 *
 *  1. **The interruption is real.** The old test "simulated process death" by constructing a second
 *     `TusTransport` over the *same* `OkHttpClient` after a cleanly completed PATCH. Nothing was
 *     ever interrupted; it proved only that a fresh object has no cached offset. Here the second
 *     PATCH is aborted from inside the request body — the production `SliceDeadlineReached` path,
 *     the one Android 15's FGS budget actually triggers — which kills the connection mid-body with
 *     a declared `Content-Length` still outstanding. The server keeps whatever it durably took.
 *  2. **The resume shares nothing.** A brand-new `OkHttpClient` (its own connection pool, its own
 *     dispatcher) re-establishes the offset with HEAD.
 *  3. **Storage is measured, not asserted.** Peak extra bytes under the JVM temp directory are
 *     sampled throughout. Invariant I6 says the transport never stages a chunk; the `kotlin / I6
 *     drift` control in `Tests/Conformance/drift-control.sh` writes its counterfactual chunk file
 *     into exactly this directory, so this is the right place to be watching.
 */
class TusdIntegrationTest {

    @Test
    fun completesAcrossAnAbortedRequestAndStagesNothingOnDisk() = runBlocking {
        val endpoint = endpointOrSkip() ?: return@runBlocking

        // A dedicated tree so the sampler below measures this test and nothing else. `java.io.tmpdir`
        // is redirected per test JVM in android/build.gradle.kts.
        val tmp = File(checkNotNull(System.getProperty("java.io.tmpdir")))
        val sourceFile = File(tmp, "amphora-tusd-source.bin")
        sourceFile.outputStream().buffered().use { out ->
            repeat(SIZE_BYTES) { out.write(it % 251) }
        }
        val expected = sha256(sourceFile.readBytes())

        val sampler = DiskSampler(tmp)
        sampler.start()
        try {
            val client = OkHttpClient()
            val transport = TusTransport(client, WireDialect.Tus10())
            val created = transport.create(endpoint, sourceFile.length(), emptyMap())
            assertEquals("a freshly created upload is not at offset 0", 0L, transport.head(created.uploadUrl).offset)

            val source = SeekableSource.fromFile(sourceFile)
            try {
                // Window one completes normally and is deliberately larger than the 5 MiB S3
                // multipart minimum (docs/reference/platform-constraints.md), so tusd has flushed a
                // real part into MinIO before anything is interrupted. Without that, the "resume"
                // could read back a number tusd was still holding in memory.
                val first = transport.patch(
                    uploadUrl = created.uploadUrl,
                    source = source,
                    offset = 0,
                    totalSize = sourceFile.length(),
                    maxBytes = PREFIX_BYTES,
                    deadlineMillis = Long.MAX_VALUE,
                    onProgress = {},
                )
                assertEquals(PREFIX_BYTES, first.ackedOffset)

                // Window two is cut off from inside the body. `now` is injected so the abort lands
                // deterministically after four 256 KiB buffers rather than depending on how fast
                // the loopback happens to be on the runner.
                val ticks = AtomicInteger(0)
                val aborting = TusTransport(
                    client, WireDialect.Tus10(),
                    now = { if (ticks.getAndIncrement() < BUFFERS_BEFORE_ABORT) 0L else ABORT_CLOCK },
                )
                try {
                    aborting.patch(
                        uploadUrl = created.uploadUrl,
                        source = source,
                        offset = first.ackedOffset,
                        totalSize = sourceFile.length(),
                        maxBytes = sourceFile.length() - first.ackedOffset,
                        deadlineMillis = 1L,
                        onProgress = {},
                    )
                    fail("the deadline did not abort the PATCH; nothing was interrupted")
                } catch (expectedAbort: java.io.IOException) {
                    // The connection died mid-body with Content-Length outstanding. That is the point.
                }
            } finally {
                source.close()
            }

            // Relaunch: a new client, a new pool, a new transport. The only thing carried across is
            // the upload URL — the offset has to come back off the wire.
            val relaunchedClient = OkHttpClient()
            val relaunched = TusTransport(relaunchedClient, WireDialect.Tus10())
            val serverOffset = relaunched.head(created.uploadUrl).offset
            assertTrue(
                "the aborted request left offset $serverOffset; expected at least the $PREFIX_BYTES already acked",
                serverOffset >= PREFIX_BYTES,
            )
            assertTrue(
                "the upload had already completed at $serverOffset; nothing was resumed",
                serverOffset < sourceFile.length(),
            )

            val resumeSource = SeekableSource.fromFile(sourceFile)
            val result = try {
                relaunched.patch(
                    uploadUrl = created.uploadUrl,
                    source = resumeSource,
                    offset = serverOffset,
                    totalSize = sourceFile.length(),
                    maxBytes = sourceFile.length() - serverOffset,
                    deadlineMillis = System.currentTimeMillis() + TimeUnit.MINUTES.toMillis(2),
                    onProgress = {},
                )
            } finally {
                resumeSource.close()
            }
            assertEquals(sourceFile.length(), result.ackedOffset)
            // The server's own answer, not the byte count this process sent, is the completion proof.
            assertEquals(sourceFile.length(), relaunched.head(created.uploadUrl).offset)

            // Bytes at rest: tusd serves the stored object back out of MinIO, so this compares the
            // S3 content with the source rather than trusting tusd's offset bookkeeping.
            relaunchedClient.newCall(Request.Builder().url(created.uploadUrl).get().build()).execute()
                .use { download ->
                    assertEquals(200, download.code)
                    assertEquals(
                        "the object stored in S3 differs from the source",
                        expected,
                        sha256(download.body!!.bytes()),
                    )
                }

            // Fail-closed interop pin: an unpinned version must not create an upload.
            val wrongVersion = Request.Builder().url(endpoint).post(ByteArray(0).toRequestBody())
                .header("Tus-Resumable", "9.9.9")
                .header("Upload-Length", "1")
                .build()
            relaunchedClient.newCall(wrongVersion).execute().use {
                assertTrue("tusd accepted an unpinned Tus-Resumable (HTTP ${it.code})", it.code in 400..599)
            }

            assertTrue(relaunched.terminate(created.uploadUrl))
            relaunchedClient.newCall(
                Request.Builder().url(created.uploadUrl).head().header("Tus-Resumable", "1.0.0").build()
            ).execute().use {
                assertTrue("terminated upload still answers HTTP ${it.code}", it.code == 404 || it.code == 410)
            }

            val extra = sampler.stopAndPeakExtraBytes()
            val evidence =
                "Kotlin real wire: ${SIZE_BYTES / 1024 / 1024} MiB uploaded across an aborted PATCH, " +
                    "resumed by a new client from server offset $serverOffset, checksum verified, " +
                    "peak extra disk ${extra / 1024} KiB"
            println(evidence)
            // Also on disk, not only on stdout. `showStandardStreams` is off, so console output
            // would be swallowed, and whether Gradle's JUnit XML carries suite-level stdout is an
            // implementation detail to depend on for the one line this whole job exists to produce.
            recordEvidence(evidence)
            assertTrue(
                "I6 violated: transferring $SIZE_BYTES bytes added $extra bytes of disk, over the $DISK_BUDGET_BYTES byte budget",
                extra <= DISK_BUDGET_BYTES,
            )
        } finally {
            sampler.stop()
            sourceFile.delete()
        }
    }

    /**
     * A missing `TUSD_ENDPOINT` is an honest skip — unless `AMPHORA_REQUIRE_DOCKER=1`, and then
     * it is a failure.
     *
     * The same split as `integration/tusd/lib.sh` and `.chief/verify.sh`, and for the same reason:
     * a developer machine legitimately has no Docker, but a run whose entire purpose is to produce
     * evidence that bytes crossed a wire must not be able to report success without them. Tasklist
     * 80 recorded exactly that.
     */
    private fun endpointOrSkip(): String? {
        val endpoint = System.getenv("TUSD_ENDPOINT")?.takeIf { it.isNotBlank() }
        if (endpoint != null) return endpoint
        // Keyed on AMPHORA_REQUIRE_DOCKER alone, NOT on CI=true: the `android` job also runs
        // `:android:testDebugUnitTest` with no server up, to drive the conformance vectors, and a
        // skip there is honest. Strictness belongs to the step whose purpose is the evidence.
        if (System.getenv("AMPHORA_REQUIRE_DOCKER") == "1") {
            fail("TUSD_ENDPOINT is unset, and a skip here would be recorded as a pass. Start integration/tusd.")
        }
        println("TusdIntegrationTest: SKIPPED — TUSD_ENDPOINT is unset. This proved nothing.")
        assumeTrue(false)
        return null
    }

    /** Writes the observation where CI can print it. Best effort: never fail the run over it. */
    private fun recordEvidence(line: String) {
        val root = System.getProperty("amphora.repoRoot") ?: return
        val report = File(root, "android/build/reports/tusd-real-wire.txt")
        runCatching {
            report.parentFile?.mkdirs()
            report.writeText(line + "\n")
        }
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    /**
     * Samples the total size of [root] on a daemon thread and remembers the maximum.
     *
     * Polling rather than a `WatchService`: a staged chunk file that is created, filled and deleted
     * inside one poll interval would be missed by a size sample, but it would also have to be
     * written and removed in under 25 ms, and the failure mode this guards against — staging the
     * remainder for the duration of the transfer — lasts as long as the upload does.
     */
    private class DiskSampler(private val root: File) {
        private val running = AtomicBoolean(true)
        private val peak = AtomicLong(0)
        private var baseline = 0L
        private var thread: Thread? = null

        /** Call once the source file is already in place: it belongs to the baseline, not to what
         *  the transfer adds. */
        fun start() {
            baseline = sizeOf(root)
            peak.set(baseline)
            thread = Thread {
                while (running.get()) {
                    val current = sizeOf(root)
                    peak.getAndUpdate { maxOf(it, current) }
                    Thread.sleep(25)
                }
            }.apply { isDaemon = true; start() }
        }

        fun stopAndPeakExtraBytes(): Long {
            stop()
            return maxOf(peak.get(), sizeOf(root)) - baseline
        }

        fun stop() {
            running.set(false)
            thread?.join(1_000)
            thread = null
        }

        private fun sizeOf(dir: File): Long =
            dir.walkTopDown().filter { it.isFile }.sumOf { it.length() }
    }

    private companion object {
        const val SIZE_BYTES = 8 * 1024 * 1024
        const val PREFIX_BYTES = 5L * 1024 * 1024 + 256 * 1024   // > the 5 MiB S3 part minimum
        const val BUFFERS_BEFORE_ABORT = 4                        // RangeRequestBody writes 256 KiB at a time
        const val ABORT_CLOCK = Long.MAX_VALUE / 2
        /** A transport that staged the remainder would need ~2.75 MiB here; the whole file, 8 MiB. */
        const val DISK_BUDGET_BYTES = 256L * 1024
    }
}
