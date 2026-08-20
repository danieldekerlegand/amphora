package dev.amphora.core

import dev.amphora.UploadRequest
import dev.amphora.model.UploadEvent
import dev.amphora.model.UploadJob
import dev.amphora.work.SliceOutcome

/**
 * Applies [UploadStateMachine] transitions and performs the effects they declare.
 *
 * The split is the point: the machine decides, the engine acts. Everything below is IO and
 * therefore untestable-by-inspection, which is exactly why none of it may contain policy.
 */
interface UploadEngine {

    suspend fun awaitReady(): ReconcileReport

    suspend fun enqueue(request: UploadRequest): String
    suspend fun pause(id: String)
    suspend fun resume(id: String)
    suspend fun cancel(id: String)
    suspend fun retry(id: String)

    /** Feed an event through the machine, persist the new row, run the effects, emit to hosts. */
    suspend fun dispatch(jobId: String, event: UploadEvent)

    /** One bounded transfer slice. Called only by [dev.amphora.work.UploadWorker]. */
    suspend fun runSlice(jobId: String, runnerToken: String, byteCeiling: Long, deadline: Long): SliceOutcome

    /** Persist the last acked offset immediately — called from onStopped(), where there are
     *  seconds, not minutes, before Android 15 kills the service. */
    suspend fun flushOffset(jobId: String)

    /** Re-check network/storage/power for a BLOCKED job and unblock if the gate has cleared. */
    suspend fun reevaluateGates(job: UploadJob)

    /** Cheap existence + fingerprint check. Deliberately not a content hash. */
    suspend fun sourceIsIntact(job: UploadJob): Boolean
}
