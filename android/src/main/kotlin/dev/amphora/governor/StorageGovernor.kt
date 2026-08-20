package dev.amphora.governor

import android.content.Context
import android.os.Build
import android.os.storage.StorageManager
import androidx.annotation.RequiresApi
import java.io.File
import java.io.RandomAccessFile
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * The component no existing upload library has.
 *
 * Android is the platform that can actually *reserve* space rather than merely observe it:
 * `getAllocatableBytes()` reports what the system would free for us, and
 * `allocateBytes(FileDescriptor, Long)` holds it against cache eviction. That is what stops the
 * OS reclaiming a staged upload out from under a suspended app.
 *
 * See docs/reference/platform-constraints.md §2.
 */
fun interface SpaceAllocator {
    fun allocate(fd: java.io.FileDescriptor, bytes: Long)
}

class StorageGovernor(
    private val context: Context,
    allocator: SpaceAllocator? = null,
) {

    private val allocator = allocator ?: SpaceAllocator { fd, bytes -> storageManager.allocateBytes(fd, bytes) }

    /** Never let staging drive the device to zero; leave the user room to breathe. */
    private val headroomBytes = 512L * 1024 * 1024

    /** Documented constraint: do not re-allocate more than once per 60s for growing files. */
    private val allocationCooldownMs = 60_000L

    private val _pressure = MutableStateFlow(StoragePressure.OK)
    val pressure: StateFlow<StoragePressure> = _pressure

    private val storageManager get() = context.getSystemService(StorageManager::class.java)

    /**
     * How many bytes we could obtain — typically *more* than free space, since the system will
     * evict other apps' caches to satisfy us.
     */
    @RequiresApi(Build.VERSION_CODES.O)
    fun allocatableBytes(): Long {
        val uuid = storageManager.getUuidForPath(context.filesDir)
        return runCatching { storageManager.getAllocatableBytes(uuid) }.getOrDefault(0L)
    }

    /**
     * Reserve space for a staged copy. Allocation failure is typed so the caller cannot
     * accidentally continue with an unreserved copy.
     */
    @RequiresApi(Build.VERSION_CODES.O)
    fun reserve(jobId: String, bytes: Long): Reservation {
        // Application-private storage, not the cache dir: cache is exactly what gets reclaimed.
        val target = File(stagingDir(), "$jobId.part")
        return try {
            RandomAccessFile(target, "rw").use { raf ->
                // Do not replace this with getAllocatableBytes(): that only observes space and
                // does not protect the staged upload from cache eviction.
                allocator.allocate(raf.fd, bytes)
            }
            Reservation(jobId, target, bytes, System.currentTimeMillis())
        } catch (error: Exception) {
            target.delete()
            throw StorageReservationDenied(jobId, bytes, error)
        }
    }

    fun release(reservation: Reservation) {
        reservation.file.delete()
    }

    /** Release a reservation after the job row has been persisted or on a failed staging copy. */
    fun releaseFor(jobId: String) {
        File(stagingDir(), "$jobId.part").delete()
    }

    fun deleteStaged(path: String) {
        File(path).delete()
    }

    /** Staged copies live here. Excluded from backup via the manifest's backup rules. */
    fun stagingDir(): File = File(context.filesDir, "amphora/staging").apply { mkdirs() }

    /**
     * "Storage space changes rapidly" is the requirement this exists for. A poll during active
     * transfer is cheap next to the transfer itself, and catches the case where another app
     * fills the disk mid-upload.
     *
     * TODO(wire): register ACTION_DEVICE_STORAGE_LOW / _OK as a fast path alongside the poll,
     *   and drive this from the worker's progress loop rather than an independent timer.
     */
    @RequiresApi(Build.VERSION_CODES.O)
    fun sample(): StoragePressure {
        val allocatable = allocatableBytes()
        val p = when {
            allocatable < headroomBytes -> StoragePressure.CRITICAL
            allocatable < headroomBytes * 3 -> StoragePressure.LOW
            else -> StoragePressure.OK
        }
        _pressure.value = p
        return p
    }

    /**
     * Reclaim staged files with no owning job row. Crash-path cleanup for state-machine I5;
     * called by the reconciler, which is the only component that knows which rows are live.
     */
    fun collectOrphans(liveStagedPaths: Set<String>): Int =
        stagingDir().listFiles().orEmpty()
            .filter { it.absolutePath !in liveStagedPaths }
            .count { it.delete() }

    data class Reservation(val jobId: String, val file: File, val bytes: Long, val acquiredAt: Long)
}

class StorageReservationDenied(
    val jobId: String,
    val requestedBytes: Long,
    cause: Throwable,
) : java.io.IOException("storage reservation denied for $jobId ($requestedBytes bytes)", cause)

enum class StoragePressure { OK, LOW, CRITICAL }
