package dev.amphora.core

import android.content.Context
import android.util.Log
import androidx.work.WorkManager
import dev.amphora.UploadRequest
import dev.amphora.governor.NetworkGovernor
import dev.amphora.governor.StorageGovernor
import dev.amphora.governor.StoragePressure
import dev.amphora.model.*
import dev.amphora.store.UploadDao
import dev.amphora.transport.*
import dev.amphora.work.SliceOutcome
import dev.amphora.work.UploadWorker
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

/**
 * Applies [UploadStateMachine] transitions and performs the effects they declare.
 *
 * The split is the point: the machine decides, the engine acts. Nothing here may contain policy —
 * if a decision appears in this file that is not in the machine, the two platforms have begun to
 * drift and the conformance vectors will not catch it.
 */
class DefaultUploadEngine(
    private val context: Context,
    private val dao: UploadDao,
    private val transport: TusTransport,
    private val storage: StorageGovernor,
    private val network: NetworkGovernor,
    private val sources: SourceResolver,
    private val emitter: EventEmitter,
    private val now: () -> Long = System::currentTimeMillis,
) : UploadEngine {

    private val readySignal = CompletableDeferred<ReconcileReport>()

    /** Serialises reduce→persist. Without it two concurrent events read the same row and the
     *  second write silently discards the first transition. */
    private val mutex = Mutex()

    override suspend fun awaitReady(): ReconcileReport = readySignal.await()

    fun completeReady(report: ReconcileReport) {
        if (!readySignal.isCompleted) readySignal.complete(report)
    }

    // ---- commands ------------------------------------------------------------

    override suspend fun enqueue(request: UploadRequest): String {
        val probe = sources.probe(request.sourceUri)
        val job = UploadJob(
            sourceKind = probe.kind,
            sourceUri = request.sourceUri,
            sizeBytes = probe.sizeBytes,
            contentType = request.contentType,
            fingerprint = request.fingerprint ?: probe.fingerprint,
            endpoint = request.endpoint,
            metadataJson = encodeMetadata(request.metadata),
            groupId = request.groupId,
            policyJson = encodePolicy(request),
            createdAt = now(),
            updatedAt = now(),
        )
        // Durable before we return the id, so a crash on the very next line still leaves a job the
        // reconciler can find.
        dao.insert(job)
        emitter.stateChanged(job)
        dispatch(job.id, UploadEvent.Schedule)
        return job.id
    }

    override suspend fun pause(id: String) = dispatch(id, UploadEvent.Pause)
    override suspend fun resume(id: String) = dispatch(id, UploadEvent.Resume)
    override suspend fun cancel(id: String) = dispatch(id, UploadEvent.Cancel)
    override suspend fun retry(id: String) = dispatch(id, UploadEvent.Retry)

    // ---- the reduce loop -----------------------------------------------------

    override suspend fun dispatch(jobId: String, event: UploadEvent) {
        val effects: List<Effect>
        val next: UploadJob

        mutex.withLock {
            val current = dao.get(jobId) ?: return
            val transition = UploadStateMachine.reduce(current, event, now())
            next = transition.job
            effects = transition.effects

            if (next != current) dao.update(next)
            else if (effects.isEmpty()) {
                // Logged, never thrown. A machine that crashes on a surprising event is a machine
                // that loses uploads in the field.
                Log.d(TAG, "no-op: ${current.state} + ${event::class.simpleName}")
                return
            }
        }

        for (effect in effects) runEffect(effect, next)
    }

    private suspend fun runEffect(effect: Effect, job: UploadJob) {
        when (effect) {
            is Effect.AcquireLease, is Effect.ReleaseLease -> Unit  // owned by the worker's lifecycle

            is Effect.EnqueueWorker ->
                UploadWorker.enqueue(context, job.id, decodePolicy(job).network, decodePolicy(job).requiresCharging)

            is Effect.CancelWorker ->
                WorkManager.getInstance(context).cancelUniqueWork(UploadWorker.tag(job.id))

            is Effect.ScheduleRetry ->
                UploadWorker.enqueueDelayed(context, job.id, effect.atEpochMillis - now())

            is Effect.ReserveSpace -> Unit                          // performed inline in prepare()
            is Effect.ReleaseReservation -> storage.releaseFor(job.id)
            is Effect.DeleteStagedFile -> storage.deleteStaged(effect.path)

            is Effect.TerminateRemote -> {
                // Best-effort. Offline, the row keeps remoteTerminated=false and the reconciler
                // retries on a later launch — the resource is never silently abandoned.
                val ok = runCatching { transport.terminate(effect.uploadUrl) }.getOrDefault(false)
                if (ok) dao.update(dao.get(job.id)!!.copy(remoteTerminated = true, updatedAt = now()))
            }

            is Effect.HeadBeforeResume -> Unit                      // performed at slice start
            is Effect.Emit -> emitter.stateChanged(dao.get(job.id) ?: job)
        }
    }

    // ---- the transfer slice --------------------------------------------------

    /**
     * One bounded unit of work, called only by [UploadWorker]. Every step feeds its result back
     * through [dispatch] rather than mutating state directly, so the machine stays the sole author
     * of every transition.
     */
    override suspend fun runSlice(
        jobId: String, runnerToken: String, byteCeiling: Long, deadline: Long,
    ): SliceOutcome {
        var job = dao.get(jobId) ?: return SliceOutcome.TERMINAL

        // Gates first — cheaper to discover here than after opening the file.
        checkGates(job)?.let { dispatch(jobId, UploadEvent.Blocked(it)); return SliceOutcome.SLICE_DONE }

        if (!sourceIsIntact(job)) {
            dispatch(jobId, UploadEvent.SourceMissing); return SliceOutcome.TERMINAL
        }

        // Create on first run. I2: the URL is persisted by the transition before any byte moves.
        if (job.uploadUrl == null) {
            val prepared = try {
                prepare(job)
            } catch (error: Exception) {
                // StorageReservationDenied no longer arrives here: SourcePreparation maps it to
                // SpaceDenied itself and returns null, which lands on the same SLICE_DONE below.
                // It moved so a conformance row can observe the event rather than the exception.
                dispatch(jobId, UploadEvent.TransportError(transport.classify(error), error.message))
                return SliceOutcome.RETRY
            } ?: return SliceOutcome.SLICE_DONE
            job = prepared
        }

        val uploadUrl = job.uploadUrl ?: return SliceOutcome.RETRY

        // I1: the server's offset, never our remembered one.
        val offset = try {
            transport.head(uploadUrl).offset
        } catch (e: UploadGone) {
            dispatch(jobId, UploadEvent.Gone); return SliceOutcome.SLICE_DONE
        } catch (e: Exception) {
            dispatch(jobId, UploadEvent.TransportError(transport.classify(e), e.message))
            return SliceOutcome.RETRY
        }
        if (offset < job.serverOffset) {
            dispatch(jobId, UploadEvent.OffsetDiverged(offset)); return SliceOutcome.SLICE_DONE
        }
        dispatch(jobId, UploadEvent.OffsetAdvanced(offset))
        if (offset >= job.sizeBytes) return finalize(jobId)

        return sources.open(job).use { file ->
            try {
                val result = transport.patch(
                    uploadUrl = uploadUrl,
                    source = file,
                    offset = offset,
                    totalSize = job.sizeBytes,
                    maxBytes = byteCeiling,
                    deadlineMillis = deadline,
                    onProgress = { emitter.progress(jobId, it, job.sizeBytes) },
                )
                dispatch(jobId, UploadEvent.OffsetAdvanced(result.ackedOffset))
                if (result.complete) finalize(jobId) else SliceOutcome.SLICE_DONE
            } catch (e: SliceDeadlineReached) {
                // Expected, not exceptional: the FGS budget ran out. Whatever the server accepted
                // is discoverable by the next HEAD, so simply hand off to a successor.
                SliceOutcome.SLICE_DONE
            } catch (e: UploadGone) {
                dispatch(jobId, UploadEvent.Gone); SliceOutcome.SLICE_DONE
            } catch (e: OffsetConflict) {
                // Never guess. Re-HEAD next slice and resume from whatever the server says.
                dispatch(jobId, UploadEvent.TransportError(ErrorClass.PROTOCOL, "offset conflict"))
                SliceOutcome.RETRY
            } catch (e: Exception) {
                dispatch(jobId, UploadEvent.TransportError(transport.classify(e), e.message))
                SliceOutcome.RETRY
            }
        }
    }

    /** The decision itself lives in [SourcePreparation] — the only unit a JVM test can drive. */
    private suspend fun prepare(job: UploadJob): UploadJob? {
        val created = SourcePreparation.prepare(
            job = job,
            sources = sources,
            storage = storage,
            dispatch = { event -> dispatch(job.id, event) },
            create = { transport.create(it.endpoint, it.sizeBytes, decodeMetadata(it.metadataJson)) },
        )
        return if (created) dao.get(job.id) else null
    }

    private suspend fun finalize(jobId: String): SliceOutcome {
        dispatch(jobId, UploadEvent.TransportComplete)
        dispatch(jobId, UploadEvent.ServerAck)
        return SliceOutcome.COMPLETE
    }

    // ---- gates ---------------------------------------------------------------

    private fun checkGates(job: UploadJob): BlockReason? {
        val policy = decodePolicy(job)
        if (!network.permits(policy.network)) {
            return if (network.status.value == dev.amphora.governor.NetworkStatus.UNAVAILABLE)
                BlockReason.NETWORK_UNAVAILABLE else BlockReason.NETWORK_DISALLOWED
        }
        // Only staged jobs can be defeated by low storage; a streamed upload needs no headroom.
        if (job.stagedPath != null && storage.sample() == StoragePressure.CRITICAL) {
            return BlockReason.STORAGE_LOW
        }
        return null
    }

    override suspend fun reevaluateGates(job: UploadJob) {
        if (checkGates(job) == null) dispatch(job.id, UploadEvent.GateCleared)
    }

    override suspend fun sourceIsIntact(job: UploadJob): Boolean = sources.isIntact(job)

    override suspend fun flushOffset(jobId: String) {
        emitter.flush(jobId)
    }

    private companion object { const val TAG = "Amphora" }
}

/** Where host-facing events go. Implemented by the RN bridge and by native Android hosts. */
interface EventEmitter {
    fun stateChanged(job: UploadJob)
    fun progress(jobId: String, bytesTransferred: Long, total: Long)
    fun flush(jobId: String)
}
