package dev.amphora

import dev.amphora.core.SeekableSource
import dev.amphora.transport.TusTransport
import dev.amphora.transport.WireDialect
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.junit.Assume.assumeNotNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Opt-in real-wire test; run with TUSD_ENDPOINT against integration/tusd. */
class TusdIntegrationTest {
    @Test
    fun completesMultiMegabyteUploadAndTerminatesResource() = runBlocking {
        val endpoint = System.getenv("TUSD_ENDPOINT")
        assumeNotNull(endpoint)
        val sourceFile = File.createTempFile("amphora-tusd-", ".bin")
        sourceFile.outputStream().use { output ->
            repeat(3 * 1024 * 1024) { output.write(it % 251) }
        }

        val client = OkHttpClient()
        val transport = TusTransport(client, WireDialect.Tus10())
        val created = transport.create(endpoint!!, sourceFile.length(), emptyMap())
        assertEquals(0L, transport.head(created.uploadUrl).offset)

        val firstWindow = sourceFile.length() * 2 / 5
        val source = SeekableSource.fromFile(sourceFile)
        try {
            val first = transport.patch(
                uploadUrl = created.uploadUrl,
                source = source,
                offset = 0,
                totalSize = sourceFile.length(),
                maxBytes = firstWindow,
                deadlineMillis = System.currentTimeMillis() + TimeUnit.MINUTES.toMillis(2),
                onProgress = {},
            )
            assertEquals(firstWindow, first.ackedOffset)

            // Simulate process death: the relaunch creates a new transport with no cached offset.
            val relaunched = TusTransport(client, WireDialect.Tus10())
            val serverOffset = relaunched.head(created.uploadUrl).offset
            assertEquals(firstWindow, serverOffset)
            val result = relaunched.patch(
                uploadUrl = created.uploadUrl,
                source = source,
                offset = serverOffset,
                totalSize = sourceFile.length(),
                maxBytes = sourceFile.length() - serverOffset,
                deadlineMillis = System.currentTimeMillis() + TimeUnit.MINUTES.toMillis(2),
                onProgress = {},
            )
            assertEquals(sourceFile.length(), result.ackedOffset)
            assertEquals(sourceFile.length(), relaunched.head(created.uploadUrl).offset)
        } finally {
            source.close()
            sourceFile.delete()
        }

        val wrongVersion = Request.Builder().url(endpoint!!).post(ByteArray(0).toRequestBody())
            .header("Tus-Resumable", "9.9.9")
            .header("Upload-Length", "1")
            .build()
        client.newCall(wrongVersion).execute().use { assertTrue(it.code in 400..599) }

        assertTrue(transport.terminate(created.uploadUrl))
        client.newCall(Request.Builder().url(created.uploadUrl).head()
            .header("Tus-Resumable", "1.0.0").build()).execute().use {
            assertTrue(it.code == 404 || it.code == 410)
        }
    }
}
