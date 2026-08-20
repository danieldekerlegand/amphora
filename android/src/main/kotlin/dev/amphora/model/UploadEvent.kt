package dev.amphora.model

/** Inputs to the state machine. See docs/reference/state-machine.md §3. */
sealed interface UploadEvent {

    // --- commands (always valid to issue; may be no-ops) -----------------------
    data object Schedule : UploadEvent
    data object Pause : UploadEvent
    data object Resume : UploadEvent
    data object Cancel : UploadEvent
    data object Retry : UploadEvent

    // --- transport signals ----------------------------------------------------
    data class SourceResolved(val sizeBytes: Long, val fingerprint: String, val stagedPath: String?) : UploadEvent
    data object SourceMissing : UploadEvent
    data class RemoteCreated(val uploadUrl: String, val expiresAt: Long?) : UploadEvent
    data class OffsetAdvanced(val serverOffset: Long) : UploadEvent
    data object TransportComplete : UploadEvent
    data object ServerAck : UploadEvent
    data class TransportError(val errorClass: ErrorClass, val detail: String?) : UploadEvent
    data object Gone : UploadEvent
    data class OffsetDiverged(val serverOffset: Long) : UploadEvent

    // --- environment ----------------------------------------------------------
    data class Blocked(val reason: BlockReason) : UploadEvent
    data object GateCleared : UploadEvent
    data object DeadlineReached : UploadEvent
    data class SpaceDenied(val needed: Long) : UploadEvent
    data object ProcessStart : UploadEvent
}

/**
 * A transition is a new row plus the side effects the caller must perform.
 * Keeping effects declarative keeps the machine pure and therefore testable.
 */
data class Transition(val job: UploadJob, val effects: List<Effect> = emptyList())

sealed interface Effect {
    data object AcquireLease : Effect
    data object ReleaseLease : Effect
    data class ReserveSpace(val bytes: Long) : Effect
    data object ReleaseReservation : Effect
    data class DeleteStagedFile(val path: String) : Effect
    data object HeadBeforeResume : Effect
    data class TerminateRemote(val uploadUrl: String) : Effect
    data class EnqueueWorker(val jobId: String) : Effect
    data class CancelWorker(val jobId: String) : Effect
    data class ScheduleRetry(val atEpochMillis: Long) : Effect
    data class Emit(val jobId: String, val state: UploadState) : Effect
}
