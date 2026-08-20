package dev.amphora.transport

import dev.amphora.core.SeekableSource
import dev.amphora.model.ErrorClass
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import okio.BufferedSink
import java.io.IOException
import java.net.URI
import java.nio.ByteBuffer

/**
 * The wire layer. Speaks whichever [WireDialect] it is given.
 *
 * Two properties matter more than anything else here:
 *
 *  1. [head] is the *only* source of truth for offset (state-machine I1). Nothing resumes from a
 *     locally remembered byte count.
 *  2. [RangeRequestBody] streams a byte window straight out of the source file. No chunk temp file
 *     is ever created (state-machine I6) — precisely the class of bug that corrupted uploads under
 *     the AWS SDK when the OS reclaimed the app's cache mid-transfer.
 */
class TusTransport(
    private val client: OkHttpClient,
    private val dialect: WireDialect = WireDialect.Tus10(),
    private val tokenProvider: suspend () -> String? = { null },
    private val now: () -> Long = System::currentTimeMillis,
) {

    suspend fun create(
        endpoint: String,
        sizeBytes: Long,
        metadata: Map<String, String>,
    ): CreateResult = withContext(Dispatchers.IO) {
        val builder = Request.Builder()
            .url(endpoint)
            .post(ByteArray(0).toRequestBody(null, 0, 0))
        dialect.decorate(builder)
        dialect.creationHeaders(sizeBytes, metadata).forEach { (k, v) -> builder.header(k, v) }
        authorize(builder)

        client.newCall(builder.build()).await().use { response ->
            // tus answers 201; RUFH answers 104 and OkHttp surfaces the final status, so accept
            // any 2xx that carries a Location rather than pinning an exact code.
            if (!response.isSuccessful && response.code != 104) {
                throw HttpFailure(response.code, "create failed")
            }
            val location = response.header("Location")
                ?: throw HttpFailure(response.code, "create response carried no Location")

            CreateResult(
                // Location MAY be relative, and tusd behind a reverse proxy commonly returns one.
                // Storing it unresolved yields a job that can never be resumed *or* terminated
                // after restart, since nothing else on the device records the base URL.
                uploadUrl = URI(endpoint).resolve(location).toString(),
                expiresAt = dialect.readExpiry(response.headers, now()),
            )
        }
    }

    /** Authoritative offset. Called before every entry into UPLOADING. */
    suspend fun head(uploadUrl: String): HeadResult = withContext(Dispatchers.IO) {
        val builder = Request.Builder().url(uploadUrl).head()
            .header("Cache-Control", "no-store")   // an intermediary caching this is catastrophic
        dialect.decorate(builder)
        authorize(builder)

        client.newCall(builder.build()).await().use { response ->
            when (response.code) {
                404, 410 -> throw UploadGone
                in 200..204 -> {
                    val offset = dialect.readOffset(response.headers)
                        ?: throw HttpFailure(response.code, "HEAD carried no Upload-Offset")
                    if (offset < 0) throw UnexpectedOffset(offset)
                    HeadResult(
                        offset = offset,
                        expiresAt = dialect.readExpiry(response.headers, now()),
                    )
                }
                else -> throw HttpFailure(response.code, "HEAD failed")
            }
        }
    }

    /**
     * Upload a bounded window starting at [offset]. Bounded rather than whole-file because of
     * Android 15's 6h/24h dataSync FGS budget — see platform-constraints.md §2. The window ends at
     * `offset + maxBytes` or when [deadlineMillis] passes, whichever comes first; the acked offset
     * is persisted and a successor worker picks up from there.
     */
    suspend fun patch(
        uploadUrl: String,
        source: SeekableSource,
        offset: Long,
        totalSize: Long,
        maxBytes: Long,
        deadlineMillis: Long,
        onProgress: (Long) -> Unit,
    ): PatchResult = withContext(Dispatchers.IO) {
        // The window is fixed before the request starts and fully written, because Content-Length
        // is declared from it. `maxBytes` is therefore a real commitment: size it so a slice
        // plausibly completes inside the FGS budget on a slow connection.
        val window = minOf(maxBytes, totalSize - offset)
        val isFinalSlice = offset + window >= totalSize

        val body = RangeRequestBody(
            source = source,
            offset = offset,
            length = window,
            contentType = dialect.appendContentType.toMediaType(),
            deadlineMillis = deadlineMillis,
            now = now,
            onProgress = onProgress,
        )

        val builder = Request.Builder().url(uploadUrl).patch(body)
        dialect.decorate(builder)
        dialect.appendHeaders(offset, isFinalSlice).forEach { (k, v) -> builder.header(k, v) }
        authorize(builder)

        client.newCall(builder.build()).await().use { response ->
            when (response.code) {
                404, 410 -> throw UploadGone
                409 -> throw OffsetConflict           // caller re-HEADs; never guess the offset
                in 200..204 -> {
                    // Never assume bytes written == bytes accepted. The response header is the
                    // acked value, and the amount actually sent may be short if the deadline cut
                    // the body off mid-window.
                    val acked = dialect.readOffset(response.headers) ?: (offset + body.bytesWritten)
                    if (acked < offset || acked > totalSize) throw UnexpectedOffset(acked)
                    PatchResult(ackedOffset = acked, complete = acked >= totalSize)
                }
                else -> throw HttpFailure(response.code, "PATCH failed")
            }
        }
    }

    /**
     * tus Termination extension. Always issuable, because the URL was persisted before the first
     * byte — that is what makes an orphaned job cancelable.
     */
    suspend fun terminate(uploadUrl: String): Boolean = withContext(Dispatchers.IO) {
        val builder = Request.Builder().url(uploadUrl).delete()
            .header("Content-Length", "0")
        dialect.decorate(builder)
        authorize(builder)

        client.newCall(builder.build()).await().use { response ->
            // Already gone is success, not failure — the resource is reclaimed either way.
            response.isSuccessful || response.code == 404 || response.code == 410
        }
    }

    private suspend fun authorize(builder: Request.Builder) {
        tokenProvider()?.let { builder.header("Authorization", it) }
    }

    /**
     * Maps HTTP reality onto the retry policy. The classification is what the state machine
     * reasons about, so it belongs here rather than scattered across call sites.
     */
    fun classify(throwable: Throwable): ErrorClass = when (throwable) {
        is UploadGone -> ErrorClass.FATAL          // caller converts to Gone before reaching here
        is UnexpectedOffset -> ErrorClass.PROTOCOL
        is OffsetConflict -> ErrorClass.PROTOCOL
        is IOException -> ErrorClass.TRANSIENT     // socket reset, timeout, network handover
        is HttpFailure -> when (throwable.code) {
            401, 403 -> ErrorClass.AUTH
            412 -> ErrorClass.PROTOCOL_VERSION     // interop version mismatch
            400, 413 -> ErrorClass.FATAL
            429, in 500..599 -> ErrorClass.TRANSIENT
            else -> ErrorClass.FATAL
        }
        else -> ErrorClass.FATAL
    }

    data class CreateResult(val uploadUrl: String, val expiresAt: Long?)
    data class HeadResult(val offset: Long, val expiresAt: Long?)
    data class PatchResult(val ackedOffset: Long, val complete: Boolean)

    companion object {
        /** Pin it. A server that outruns the deployed app population must fail loudly and
         *  distinguishably, not as a generic upload error. See platform-constraints.md §5. */
        const val INTEROP_VERSION = "8"
    }
}

object UploadGone : Exception("upload resource no longer exists")
object OffsetConflict : Exception("server offset disagrees with ours")
class UnexpectedOffset(val actual: Long) : Exception("server returned unexpected offset $actual")

/** Not an error: the slice ran out of foreground-service budget. Resume via HEAD. */
object SliceDeadlineReached : IOException("slice deadline reached")

/** The source file shrank mid-transfer. Fingerprint check on the next attempt will catch it. */
object SourceTruncated : IOException("source file ended before the declared window")
class HttpFailure(val code: Int, message: String) : Exception("$message (HTTP $code)")

/**
 * Streams `[offset, offset + length)` from the original file. Zero extra storage.
 *
 * `isOneShot() = true` stops OkHttp retrying the body itself — retries must go through the state
 * machine so the offset is re-established via HEAD first (I1). A silent OkHttp replay would resend
 * from the wrong offset and be rejected with a 409 at best.
 */
class RangeRequestBody(
    private val source: SeekableSource,
    private val offset: Long,
    private val length: Long,
    private val contentType: MediaType,
    private val deadlineMillis: Long,
    private val now: () -> Long,
    private val onProgress: (Long) -> Unit,
) : RequestBody() {

    @Volatile var bytesWritten: Long = 0
        private set

    override fun contentType() = contentType
    override fun contentLength() = length
    override fun isOneShot() = true

    override fun writeTo(sink: BufferedSink) {
        source.channel.position(offset)
        val buf = ByteBuffer.allocate(BUFFER_BYTES)
        while (bytesWritten < length) {
            // The deadline is the Android 15 FGS budget made concrete. It must ABORT the request,
            // never short-write it: Content-Length is already declared as `length`, so returning
            // early would send a truncated body under a full-length header. Throwing kills the
            // connection, the server keeps whatever it durably accepted, and the next HEAD reports
            // that offset — which is exactly the resume path we already have.
            if (now() >= deadlineMillis) throw SliceDeadlineReached

            val want = minOf(BUFFER_BYTES.toLong(), length - bytesWritten).toInt()
            buf.clear().limit(want)
            val read = source.channel.read(buf)
            // A short read before `length` means the file changed underneath us. Aborting is the
            // only safe move; padding would corrupt the upload silently.
            if (read <= 0) throw SourceTruncated
            sink.write(buf.array(), 0, read)
            bytesWritten += read
            onProgress(offset + bytesWritten)   // coalesced downstream, not emitted per buffer (I9)
        }
        sink.flush()
    }

    companion object { private const val BUFFER_BYTES = 256 * 1024 }
}
