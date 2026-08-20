package dev.amphora.core

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import dev.amphora.governor.StorageGovernor
import dev.amphora.model.SourceKind
import dev.amphora.model.UploadJob
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest

/**
 * Turns a caller-supplied URI into something seekable, copying only when it must.
 *
 * The decision ladder is the whole point (persistence-and-recovery.md §3): a real file, or a
 * content provider that supports seeking, costs **zero** extra storage. Only a non-seekable
 * provider stream forces a staged copy — and that is the single path where low storage can block
 * an upload.
 */
class SourceResolver(private val context: Context) {

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
     * Open for byte-range reads. Prefers the original; falls back to the staged copy.
     * `RandomAccessFile` rather than a stream, because resuming means seeking.
     */
    fun open(job: UploadJob): RandomAccessFile {
        job.stagedPath?.let { return RandomAccessFile(it, "r") }
        val parsed = Uri.parse(job.sourceUri)
        if (parsed.scheme == null || parsed.scheme == "file") {
            return RandomAccessFile(parsed.path!!, "r")
        }
        // Many providers hand back a real seekable fd. Trying costs nothing and saves a full copy.
        val pfd = context.contentResolver.openFileDescriptor(parsed, "r")
            ?: error("cannot open ${job.sourceUri}")
        return RandomAccessFile(pfd.fileDescriptor.let { java.io.FileDescriptor() }.let {
            // TODO(impl): wrap the ParcelFileDescriptor without losing seekability — the current
            //   expression drops it. Use ParcelFileDescriptor.AutoCloseInputStream + FileChannel,
            //   or stage when the provider reports a pipe rather than a file.
            error("seekable content:// path not yet wired")
        }, "r")
    }

    /** Returns a staged file only when the source genuinely cannot be seeked. */
    fun stageIfRequired(job: UploadJob, storage: StorageGovernor): File? {
        if (job.stagedPath != null) return File(job.stagedPath)
        if (job.sourceKind == SourceKind.FILE) return null
        return runCatching { open(job).close(); null }
            .getOrElse {
                // TODO(impl): reserve via storage.reserve(job.id, job.sizeBytes), then stream the
                //   provider into it, re-sampling pressure so a mid-copy squeeze aborts cleanly.
                null
            }
    }

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
