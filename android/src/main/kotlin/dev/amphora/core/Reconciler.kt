package dev.amphora.core

import android.content.Context
import androidx.work.WorkInfo
import androidx.work.WorkManager
import dev.amphora.model.*
import dev.amphora.store.UploadDao
import dev.amphora.transport.TusTransport
import dev.amphora.work.UploadWorker

/**
 * The join between the two registries.
 *
 * Our Room database says what *should* be happening. WorkManager's own database — which survives
 * process death and reboot — says what *is*. Reconciliation is the intersection, and it is the
 * whole answer to "the user closed the app, reopened it, and expects to find their upload".
 *
 * Runs once per process start, before the host app is told the module is ready.
 * See docs/reference/persistence-and-recovery.md §5.
 */
class Reconciler(
    private val context: Context,
    private val dao: UploadDao,
    private val transport: TusTransport,
    private val engine: UploadEngine,
    private val storage: dev.amphora.governor.StorageGovernor,
    private val now: () -> Long = System::currentTimeMillis,
) {

    suspend fun reconcile(): ReconcileReport {
        var adopted = 0; var recovered = 0; var expired = 0; var failed = 0

        // 1–2. Working set, and free leases held by processes that no longer exist.
        dao.breakStaleLeases(now())
        val unfinished = dao.unfinished()

        // 3. What is genuinely still running?
        val live = liveWorkJobIds()

        for (job in unfinished) {
            if (job.id in live) {
                // ADOPT. Do not restart: a running worker plus a fresh one is two writers on one
                // upload URL, which corrupts silently. The lease would catch it, but not racing
                // in the first place is cheaper.
                adopted++
                continue
            }
            when (job.state) {
                UploadState.PAUSED -> Unit                       // sticky by design
                UploadState.BLOCKED -> engine.reevaluateGates(job)
                else -> { recoverOne(job).let { r -> when (r) {
                    Recovery.EXPIRED -> expired++
                    Recovery.FAILED -> failed++
                    Recovery.RESUMABLE -> recovered++
                    Recovery.DEFERRED -> Unit
                } } }
            }
        }

        // 5. Crash-path cleanup (state-machine I5).
        val orphanedFiles = storage.collectOrphans(dao.liveStagedPaths().toSet())
        retryPendingTerminations()

        return ReconcileReport(adopted, recovered, expired, failed, orphanedFiles)
    }

    private suspend fun recoverOne(job: UploadJob): Recovery {
        engine.dispatch(job.id, UploadEvent.ProcessStart)   // → RECOVERING

        // a. Is the source still there and unchanged?
        if (!engine.sourceIsIntact(job)) {
            engine.dispatch(job.id, UploadEvent.SourceMissing); return Recovery.FAILED
        }
        // b. Never created remotely — nothing to resume, start clean.
        if (job.uploadUrl == null) {
            engine.dispatch(job.id, UploadEvent.Retry); return Recovery.RESUMABLE
        }
        // c. Server-side lifetime elapsed.
        if (job.uploadExpiresAt != null && job.uploadExpiresAt < now()) {
            engine.dispatch(job.id, UploadEvent.Gone); return Recovery.EXPIRED
        }
        // d. Ask the only authority there is.
        return try {
            val head = transport.head(job.uploadUrl)
            when {
                head.offset < job.serverOffset -> {            // I7: never resume downward
                    engine.dispatch(job.id, UploadEvent.OffsetDiverged(head.offset)); Recovery.EXPIRED
                }
                else -> {
                    engine.dispatch(job.id, UploadEvent.OffsetAdvanced(head.offset)); Recovery.RESUMABLE
                }
            }
        } catch (e: Exception) {
            // An offline launch must still list and cancel jobs; only *resuming* needs network.
            engine.dispatch(job.id, UploadEvent.Blocked(BlockReason.NETWORK_UNAVAILABLE))
            Recovery.DEFERRED
        }
    }

    /** Cancelations whose DELETE never landed, because the device was offline at the time. */
    private suspend fun retryPendingTerminations() {
        for (job in dao.pendingTerminations()) {
            val url = job.uploadUrl ?: continue
            runCatching { transport.terminate(url) }
                .onSuccess { dao.update(job.copy(remoteTerminated = true, updatedAt = now())) }
        }
    }

    private fun liveWorkJobIds(): Set<String> =
        WorkManager.getInstance(context)
            .getWorkInfosByTag(WORK_TAG_PREFIX).get()
            .filter { it.state == WorkInfo.State.RUNNING || it.state == WorkInfo.State.ENQUEUED }
            .flatMap { info -> info.tags.mapNotNull { it.removePrefixOrNull("$WORK_TAG_PREFIX:") } }
            .toSet()

    private fun String.removePrefixOrNull(p: String) = if (startsWith(p)) removePrefix(p) else null

    private enum class Recovery { RESUMABLE, EXPIRED, FAILED, DEFERRED }

    companion object { private const val WORK_TAG_PREFIX = "amphora-job" }
}

data class ReconcileReport(
    val adopted: Int,
    val recovered: Int,
    val expired: Int,
    val failed: Int,
    val orphanedFilesRemoved: Int,
)
