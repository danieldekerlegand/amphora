package dev.amphora.transport

import android.util.Base64
import okhttp3.Headers
import okhttp3.Request
import java.time.Instant
import java.time.format.DateTimeFormatter

/**
 * The seam between tus 1.0 and the IETF draft. See docs/reference/wire-protocol.md.
 *
 * Kept as a dialect rather than conditionals inside the transport because the two protocols differ
 * in header names, content types *and* expiry semantics — scattering that produces a transport
 * where no single reading tells you which wire you are actually speaking.
 */
sealed interface WireDialect {

    val appendContentType: String

    fun decorate(builder: Request.Builder): Request.Builder
    fun creationHeaders(sizeBytes: Long, metadata: Map<String, String>): Map<String, String>
    fun appendHeaders(offset: Long, isFinalSlice: Boolean): Map<String, String>
    fun readOffset(headers: Headers): Long?
    fun readExpiry(headers: Headers, now: Long): Long?

    /** tus 1.0. The dialect tusd has spoken in production for a decade. */
    data class Tus10(private val version: String = "1.0.0") : WireDialect {

        override val appendContentType = "application/offset+octet-stream"

        override fun decorate(builder: Request.Builder): Request.Builder =
            builder.header("Tus-Resumable", version)

        override fun creationHeaders(sizeBytes: Long, metadata: Map<String, String>) = buildMap {
            put("Upload-Length", sizeBytes.toString())
            if (metadata.isNotEmpty()) put("Upload-Metadata", encodeMetadata(metadata))
        }

        override fun appendHeaders(offset: Long, isFinalSlice: Boolean) =
            mapOf("Upload-Offset" to offset.toString())

        override fun readOffset(headers: Headers) = headers["Upload-Offset"]?.toLongOrNull()

        override fun readExpiry(headers: Headers, now: Long): Long? =
            headers["Upload-Expires"]?.let {
                runCatching { Instant.from(DateTimeFormatter.RFC_1123_DATE_TIME.parse(it)).toEpochMilli() }
                    .getOrNull()
            }

        /**
         * `key <base64>, key2 <base64>` — space between key and value, comma between pairs.
         * NO_WRAP matters: Android's default base64 inserts newlines, which corrupts a header.
         */
        private fun encodeMetadata(metadata: Map<String, String>): String =
            metadata.entries.joinToString(",") { (k, v) ->
                require(!k.contains(' ') && !k.contains(',')) { "invalid metadata key: $k" }
                "$k ${Base64.encodeToString(v.toByteArray(), Base64.NO_WRAP)}"
            }
    }

    /** draft-ietf-httpbis-resumable-upload. What iOS 17+ speaks natively. */
    data class Rufh(private val interopVersion: String = TusTransport.INTEROP_VERSION) : WireDialect {

        override val appendContentType = "application/partial-upload"

        override fun decorate(builder: Request.Builder): Request.Builder =
            builder.header("Upload-Draft-Interop-Version", interopVersion)

        override fun creationHeaders(sizeBytes: Long, metadata: Map<String, String>) = mapOf(
            // Structured-field booleans. ?1 means "this request carries the whole representation".
            "Upload-Complete" to "?1",
            "Upload-Length" to sizeBytes.toString(),
        )

        override fun appendHeaders(offset: Long, isFinalSlice: Boolean) = mapOf(
            "Upload-Offset" to offset.toString(),
            "Upload-Complete" to if (isFinalSlice) "?1" else "?0",
        )

        override fun readOffset(headers: Headers) = headers["Upload-Offset"]?.toLongOrNull()

        /** RUFH expresses lifetime as `Upload-Limit: max-age=<seconds>`, not an absolute date. */
        override fun readExpiry(headers: Headers, now: Long): Long? =
            headers["Upload-Limit"]
                ?.split(",")
                ?.map(String::trim)
                ?.firstOrNull { it.startsWith("max-age=") }
                ?.removePrefix("max-age=")
                ?.toLongOrNull()
                ?.let { now + it * 1000 }
    }
}
