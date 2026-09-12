package dev.amphora.core

import android.content.Context
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import dev.amphora.governor.StorageGovernor
import dev.amphora.model.SourceKind
import dev.amphora.model.UploadJob
import java.io.File
import java.io.FileInputStream
import java.io.RandomAccessFile
import java.nio.channels.Channels
import java.security.MessageDigest

/**
 * Turns a caller-supplied URI into something seekable, copying only when it must.
 *
 * The decision ladder is the whole point (persistence-and-recovery.md §3): a real file, or a
 * content provider that supports seeking, costs **zero** extra storage. Only a non-seekable
 * provider stream forces a staged copy — and that is the single path where low storage can block
 * an upload.
 */
class SourceResolver(
    private val context: Context,
    private val content: ContentSource = AndroidContentSource(context),
) {

    fun probe(uri: String): Probe {
        val parsed = Uri.parse(uri)
        return when (parsed.scheme) {
            null, "file" -> {
                val file = File(parsed.path!!)
                Probe(SourceKind.FILE, file.length(), fingerprint(uri, file.length(), file.lastModified()))
            }
            else -> {
                val (size, name) = queryContent(parsed)
                Probe(SourceKind.CONTENT_URI, size, fingerprint(uri, size, name.hashCode().toLong()))
            }
        }
    }

    /** Cheap: (uri, size, mtime). Hashing 4 GB every launch costs minutes and battery for a check
     *  this already answers. See persistence-and-recovery.md §6. */
    private fun fingerprint(uri: String, size: Long, mtime: Long): String =
        MessageDigest.getInstance("SHA-256")
            .digest("$uri|$size|$mtime".toByteArray())
            .joinToString("") { "%02x".format(it) }
            .take(32)

    fun isIntact(job: UploadJob): Boolean = runCatching {
        probe(job.stagedPath?.let { "file://$it" } ?: job.sourceUri).fingerprint == job.fingerprint ||
            job.stagedPath?.let { File(it).exists() } == true
    }.getOrDefault(false)

    /**
     * Open for byte-range reads. The provider decides whether the descriptor is seekable at
     * runtime; a seekable descriptor is streamed directly and is never copied to staging.
     */
    fun open(job: UploadJob): SeekableSource {
        job.stagedPath?.let { return SeekableSource.fromFile(File(it)) }
        // The row's own kind, not a re-parse of the URI. `probe` derived it from the scheme at
        // enqueue, so the two answers are the same one — and routing on it keeps `Uri.parse` and
        // every ContentResolver call on the far side of [ContentSource], which is what lets a JVM
        // test present a provider at all.
        if (job.sourceKind == SourceKind.FILE) {
            return SeekableSource.fromFile(File(Uri.parse(job.sourceUri).path!!))
        }
        return content.openSeekable(job.sourceUri)
    }

    /** Returns a staged file only when the source genuinely cannot be seeked. */
    fun stageIfRequired(job: UploadJob, storage: StorageGovernor): File? {
        if (job.stagedPath != null) return File(job.stagedPath)
        if (job.sourceKind == SourceKind.FILE) return null

        return try {
            open(job).use { null }
        } catch (_: NonSeekableSourceException) {
            val reservation = storage.reserve(job.id, job.sizeBytes)
            try {
                content.openStream(job.sourceUri).use { source ->
                    RandomAccessFile(reservation.file, "rw").use { target ->
                        target.seek(0)
                        val copied = source.copyTo(Channels.newOutputStream(target.channel))
                        target.setLength(copied)
                    }
                }
                reservation.file
            } catch (error: Throwable) {
                storage.release(reservation)
                throw error
            }
        }
    }

    class NonSeekableSourceException(uri: String, cause: Throwable) :
        java.io.IOException("content provider is not seekable: $uri", cause)

    private fun queryContent(uri: Uri): Pair<Long, String> {
        context.contentResolver.query(uri, null, null, null, null)?.use { c ->
            val sizeIdx = c.getColumnIndex(OpenableColumns.SIZE)
            val nameIdx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (c.moveToFirst()) {
                return (if (sizeIdx >= 0) c.getLong(sizeIdx) else 0L) to
                    (if (nameIdx >= 0) c.getString(nameIdx) else uri.toString())
            }
        }
        return 0L to uri.toString()
    }

    data class Probe(val kind: SourceKind, val sizeBytes: Long, val fingerprint: String)
}

/** A seekable source whose channel can serve byte ranges without creating a copy. */
class SeekableSource private constructor(
    private val input: FileInputStream,
    private val descriptor: ParcelFileDescriptor? = null,
) : AutoCloseable {
    val channel = input.channel

    override fun close() {
        runCatching { input.close() }
        descriptor?.close()
    }

    companion object {
        fun fromFile(file: File) = SeekableSource(FileInputStream(file))

        fun fromDescriptor(pfd: ParcelFileDescriptor): SeekableSource =
            SeekableSource(FileInputStream(pfd.fileDescriptor), pfd)
    }
}
