package dev.amphora.core

import android.content.Context
import android.net.Uri
import android.system.Os
import android.system.OsConstants
import java.io.InputStream

/**
 * Every `ContentResolver` touchpoint on the `content://` path, behind one seam.
 *
 * Two questions are asked of a provider and nothing else is: *can this descriptor be seeked* —
 * which decides whether a byte range streams for free or a copy has to be staged — and, when it
 * cannot, *give me the bytes*. Both are unanswerable in a JVM unit test without this seam: the
 * mockable `android.jar` stubs `ContentResolver`, and with `isReturnDefaultValues` on,
 * [Os.lseek] returns `0` for every descriptor, which reads as "seekable" no matter what the
 * provider actually is. So the one decision that matters here would always answer the same way,
 * and the staging rows in `Tests/Conformance/vectors.json` could not present both sources.
 *
 * The iOS twin is `PhotosAssetSource`, for the same reason and with the same shape.
 */
interface ContentSource {

    /**
     * Open for byte-range reads. Throws [SourceResolver.NonSeekableSourceException] when the
     * provider hands back a descriptor that cannot be seeked — a pipe or a socket — which is the
     * single Android path that forces a staged copy.
     */
    fun openSeekable(uri: String): SeekableSource

    /** Forward-only bytes: the input side of a staging copy, used only after [openSeekable] threw. */
    fun openStream(uri: String): InputStream
}

/** The default — the `ContentResolver` code, moved rather than rewritten. */
class AndroidContentSource(private val context: Context) : ContentSource {

    override fun openSeekable(uri: String): SeekableSource {
        val pfd = context.contentResolver.openFileDescriptor(Uri.parse(uri), "r")
            ?: error("cannot open $uri")
        return try {
            // Pipes and sockets throw ErrnoException(ESPIPE) here. This is deliberately a probe,
            // not a URI-scheme assumption: providers are allowed to expose either kind of
            // descriptor. ParcelFileDescriptor has no seek of its own — lseek(2) on the raw
            // descriptor is the only way to ask the question.
            check(Os.lseek(pfd.fileDescriptor, 0L, OsConstants.SEEK_SET) >= 0L) {
                "provider returned an invalid seek position"
            }
            SeekableSource.fromDescriptor(pfd)
        } catch (error: Throwable) {
            pfd.close()
            throw SourceResolver.NonSeekableSourceException(uri, error)
        }
    }

    override fun openStream(uri: String): InputStream =
        context.contentResolver.openInputStream(Uri.parse(uri)) ?: error("cannot open $uri")
}
