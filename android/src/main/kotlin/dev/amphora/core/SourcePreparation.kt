package dev.amphora.core

import dev.amphora.governor.StorageGovernor
import dev.amphora.governor.StorageReservationDenied
import dev.amphora.model.SourceKind
import dev.amphora.model.UploadEvent
import dev.amphora.model.UploadJob
import dev.amphora.transport.TusTransport
import java.io.File

/**
 * The engine's preparation step, extracted whole so something can drive it.
 *
 * Nominally this is [DefaultUploadEngine]'s business, and it was — a private `prepare()` reachable
 * only through a `DefaultUploadEngine` that cannot be constructed on the JVM at all (it wants a
 * `WorkManager` and a concrete `TusTransport`). The consequence is written down in
 * `Tests/Conformance/vectors.json`: the staging decision is the one step with no test of any
 * kind on either port, and Swift's went missing entirely — `SourceResolver.stageIfRequired` had
 * zero callers while forty conformance vectors reported green.
 *
 * So the decision lives here, with its two effects passed in, and the shared `sourceStaging` rows
 * drive **this** function. The anchor matters: the defect was a missing CALLER, so a row that
 * called `stageIfRequired` directly would have been green against the bug.
 *
 * Nothing here is policy. `SourceResolved` and `SpaceDenied` are the machine's own events; this
 * only decides which one the source justifies, in the order the machine requires — the copy
 * before the remote exists, because a reservation refused after `create` has already orphaned a
 * server resource.
 */
object SourcePreparation {

    /**
     * Stage if the source demands it, announce the source, then create the remote.
     *
     * @param dispatch every event goes through the machine; this never writes a row itself.
     * @param create the remote-creation call, supplied by the engine so a row can observe whether
     *   it happened at all. A refused reservation must never reach it.
     * @return `true` when the remote was created. `false` means the job was blocked and the
     *   caller has nothing further to do this slice.
     */
    suspend fun prepare(
        job: UploadJob,
        sources: SourceResolver,
        storage: StorageGovernor,
        dispatch: suspend (UploadEvent) -> Unit,
        create: suspend (UploadJob) -> TusTransport.CreateResult,
    ): Boolean {
        val staged: File? = try {
            sources.stageIfRequired(job, storage)
                ?: if (job.sourceKind == SourceKind.CONTENT_URI && job.stagedPath == null) {
                    dispatch(UploadEvent.SpaceDenied(job.sizeBytes)); return false
                } else null
        } catch (denied: StorageReservationDenied) {
            // The provider cannot be streamed and the OS refused the real reservation. Typed as
            // SpaceDenied so the machine blocks instead of creating remotely.
            dispatch(UploadEvent.SpaceDenied(denied.requestedBytes))
            return false
        }

        dispatch(UploadEvent.SourceResolved(job.sizeBytes, job.fingerprint, staged?.path))

        val created = create(job)
        dispatch(UploadEvent.RemoteCreated(created.uploadUrl, created.expiresAt))
        return true
    }
}
