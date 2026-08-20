package dev.amphora.core

import dev.amphora.model.*
import kotlin.math.min
import kotlin.math.pow

/**
 * The transition function. Pure: no IO, no clock reads beyond the injected `now`, no coroutines.
 *
 * Everything the platform layers disagree about — when to resume on a metered network, whether a
 * 409 is fatal — is decided here exactly once, so Swift and Kotlin cannot drift. The Swift port
 * is a line-by-line mirror of this file and both run the same conformance vectors.
 *
 * See docs/reference/state-machine.md §2.
 */
object UploadStateMachine {

    const val MAX_ATTEMPTS = 12
    private const val LEASE_DURATION_MS = 120_000L

    fun reduce(job: UploadJob, event: UploadEvent, now: Long): Transition {
        // Cancel and ProcessStart are legal from every non-terminal state, so handle them first
        // rather than repeating them in each branch.
        when (event) {
            is UploadEvent.Cancel -> if (!job.isTerminal) return cancel(job, now)
            is UploadEvent.ProcessStart -> if (!job.isTerminal && job.state != UploadState.RECOVERING) {
                return t(job.copy(state = UploadState.RECOVERING, ownerToken = null, updatedAt = now))
            }
            else -> Unit
        }

        return when (job.state) {
            UploadState.PENDING -> when (event) {
                is UploadEvent.Schedule -> t(
                    job.copy(state = UploadState.PREPARING, updatedAt = now,
                             leaseExpiresAt = now + LEASE_DURATION_MS),
                    Effect.AcquireLease, emit(job.id, UploadState.PREPARING),
                )
                else -> noop(job)
            }

            UploadState.PREPARING -> when (event) {
                is UploadEvent.SourceResolved -> t(
                    job.copy(
                        state = UploadState.CREATING,
                        sizeBytes = event.sizeBytes,
                        fingerprint = event.fingerprint,
                        stagedPath = event.stagedPath,
                        sourceKind = if (event.stagedPath != null) SourceKind.STAGED_COPY else job.sourceKind,
                        updatedAt = now,
                    ),
                    emit(job.id, UploadState.CREATING),
                )
                is UploadEvent.SourceMissing -> fail(job, ErrorClass.SOURCE_GONE, "source no longer readable", now)
                is UploadEvent.SpaceDenied -> block(job, BlockReason.STORAGE_LOW, now)
                is UploadEvent.TransportError -> classify(job, event, now)
                else -> noop(job)
            }

            // I2: uploadUrl is persisted here, before a single byte is sent. Violating this
            // orphans a server resource that can never be resumed *or* deleted.
            UploadState.CREATING -> when (event) {
                is UploadEvent.RemoteCreated -> t(
                    job.copy(
                        state = UploadState.UPLOADING,
                        uploadUrl = event.uploadUrl,
                        uploadExpiresAt = event.expiresAt,
                        remoteTerminated = false,
                        attemptCount = 0,
                        updatedAt = now,
                    ),
                    emit(job.id, UploadState.UPLOADING),
                )
                is UploadEvent.TransportError -> classify(job, event, now)
                is UploadEvent.Blocked -> block(job, event.reason, now)
                is UploadEvent.Pause -> pause(job, now)
                else -> noop(job)
            }

            UploadState.UPLOADING -> when (event) {
                // Only ever written from an acked response. I7: never accept a lower offset.
                is UploadEvent.OffsetAdvanced ->
                    if (event.serverOffset < job.serverOffset) expire(job, now)
                    else t(job.copy(
                        serverOffset = event.serverOffset,
                        bytesTransferred = event.serverOffset,
                        serverOffsetAt = now,
                        updatedAt = now,
                    ))
                is UploadEvent.TransportComplete ->
                    t(job.copy(state = UploadState.FINALIZING, updatedAt = now), emit(job.id, UploadState.FINALIZING))
                is UploadEvent.OffsetDiverged, is UploadEvent.Gone -> expire(job, now)
                is UploadEvent.TransportError -> classify(job, event, now)
                is UploadEvent.Blocked -> block(job, event.reason, now)
                is UploadEvent.Pause -> pause(job, now)
                else -> noop(job)
            }

            UploadState.FINALIZING -> when (event) {
                is UploadEvent.ServerAck -> t(
                    job.copy(
                        state = UploadState.COMPLETED,
                        bytesTransferred = job.sizeBytes,
                        serverOffset = job.sizeBytes,
                        completedAt = now,
                        updatedAt = now,
                        ownerToken = null,
                        remoteTerminated = true,
                    ),
                    Effect.ReleaseReservation, Effect.ReleaseLease,
                    *job.stagedPath?.let { arrayOf<Effect>(Effect.DeleteStagedFile(it)) }.orEmpty(),
                    emit(job.id, UploadState.COMPLETED),
                )
                is UploadEvent.TransportError -> classify(job, event, now)
                is UploadEvent.Gone -> expire(job, now)
                else -> noop(job)
            }

            // All three resume through HEAD, never from a cached local offset (I1).
            UploadState.PAUSED -> when (event) {
                is UploadEvent.Resume -> resume(job, now)
                else -> noop(job)
            }
            UploadState.BLOCKED -> when (event) {
                is UploadEvent.GateCleared -> resume(job, now)
                is UploadEvent.Resume -> resume(job, now)
                is UploadEvent.Pause -> pause(job, now)
                is UploadEvent.Blocked -> t(job.copy(blockReason = event.reason, updatedAt = now))
                else -> noop(job)
            }
            UploadState.RETRY_WAIT -> when (event) {
                is UploadEvent.AttemptsExhausted -> fail(job, ErrorClass.TRANSIENT, null, now)
                is UploadEvent.DeadlineReached -> resume(job, now)
                is UploadEvent.Pause -> pause(job, now)
                is UploadEvent.Blocked -> block(job, event.reason, now)
                else -> noop(job)
            }

            // The reconciler drives this one; it feeds results back as ordinary events.
            UploadState.RECOVERING -> when (event) {
                is UploadEvent.SourceMissing -> fail(job, ErrorClass.SOURCE_GONE, "source no longer readable", now)
                is UploadEvent.OffsetAdvanced ->
                    if (event.serverOffset < job.serverOffset) expire(job, now)
                    else if (event.serverOffset >= job.sizeBytes)
                        t(job.copy(state = UploadState.FINALIZING, serverOffset = event.serverOffset,
                                   serverOffsetAt = now, updatedAt = now), emit(job.id, UploadState.FINALIZING))
                    else t(job.copy(state = UploadState.UPLOADING, serverOffset = event.serverOffset,
                                    bytesTransferred = event.serverOffset, serverOffsetAt = now, updatedAt = now),
                           Effect.EnqueueWorker(job.id), emit(job.id, UploadState.UPLOADING))
                is UploadEvent.Gone -> expire(job, now)
                is UploadEvent.Blocked -> block(job, event.reason, now)
                is UploadEvent.Pause -> pause(job, now)
                is UploadEvent.TransportError -> classify(job, event, now)
                else -> noop(job)
            }

            UploadState.EXPIRED, UploadState.FAILED -> when (event) {
                is UploadEvent.Retry -> t(
                    job.copy(state = UploadState.PENDING, uploadUrl = null, uploadExpiresAt = null,
                             serverOffset = 0, bytesTransferred = 0, attemptCount = 0,
                             errorClass = null, errorDetail = null, blockReason = null, updatedAt = now),
                    Effect.EnqueueWorker(job.id), emit(job.id, UploadState.PENDING),
                )
                else -> noop(job)
            }

            UploadState.COMPLETED, UploadState.CANCELED -> noop(job) // I4: absorbing
        }
    }

    // ---- helpers -------------------------------------------------------------

    /**
     * A transport failure that still moved the offset forward does not consume the retry budget.
     * Without this rule a large upload on flaky Wi-Fi exhausts its attempts while making steady
     * forward progress — the most common way a technically-correct uploader fails a real user.
     */
    private fun classify(job: UploadJob, e: UploadEvent.TransportError, now: Long): Transition = when (e.errorClass) {
        ErrorClass.FATAL, ErrorClass.PROTOCOL_VERSION -> fail(job, e.errorClass, e.detail, now)
        ErrorClass.AUTH -> if (job.attemptCount == 0) retryWait(job, now, e) else fail(job, ErrorClass.AUTH, e.detail, now)
        ErrorClass.LOCAL -> block(job, BlockReason.STORAGE_LOW, now)
        else -> retryWait(job, now, e)
    }

    private fun retryWait(job: UploadJob, now: Long, e: UploadEvent.TransportError): Transition {
        val madeProgress = job.serverOffsetAt >= job.updatedAt
        val attempts = if (madeProgress) job.attemptCount else job.attemptCount + 1
        if (attempts >= MAX_ATTEMPTS) return fail(job, e.errorClass, e.detail, now)
        val backoff = min(2.0.pow(attempts.coerceAtMost(8)).toLong() * 1_000L, 300_000L)
        val at = now + backoff
        return t(
            job.copy(state = UploadState.RETRY_WAIT, attemptCount = attempts, nextAttemptAt = at,
                     errorClass = e.errorClass, errorDetail = e.detail, updatedAt = now),
            Effect.ScheduleRetry(at), emit(job.id, UploadState.RETRY_WAIT),
        )
    }

    private fun resume(job: UploadJob, now: Long) = t(
        job.copy(state = UploadState.UPLOADING, pauseReason = null, blockReason = null,
                 nextAttemptAt = null, updatedAt = now),
        Effect.HeadBeforeResume, Effect.EnqueueWorker(job.id), emit(job.id, UploadState.UPLOADING),
    )

    private fun pause(job: UploadJob, now: Long) = t(
        job.copy(state = UploadState.PAUSED, pauseReason = PauseReason.USER, blockReason = null,
                 ownerToken = null, updatedAt = now),
        Effect.CancelWorker(job.id), Effect.ReleaseLease, emit(job.id, UploadState.PAUSED),
    )

    private fun block(job: UploadJob, reason: BlockReason, now: Long) = t(
        job.copy(state = UploadState.BLOCKED, blockReason = reason, ownerToken = null, updatedAt = now),
        Effect.CancelWorker(job.id), Effect.ReleaseLease, emit(job.id, UploadState.BLOCKED),
    )

    private fun expire(job: UploadJob, now: Long) = t(
        job.copy(state = UploadState.EXPIRED, uploadUrl = null, serverOffset = 0, bytesTransferred = 0,
                 remoteTerminated = true, ownerToken = null, updatedAt = now),
        Effect.ReleaseReservation, Effect.ReleaseLease, emit(job.id, UploadState.EXPIRED),
    )

    private fun fail(job: UploadJob, cls: ErrorClass, detail: String?, now: Long) = t(
        job.copy(state = UploadState.FAILED, errorClass = cls, errorDetail = detail,
                 ownerToken = null, updatedAt = now),
        Effect.ReleaseReservation, Effect.ReleaseLease, emit(job.id, UploadState.FAILED),
    )

    private fun cancel(job: UploadJob, now: Long): Transition {
        // I2 pays off here: the URL was persisted before the first byte, so an orphaned job the
        // app has never seen running is still cancelable. Offline, this is retried on next launch.
        val terminate = job.uploadUrl?.let { listOf(Effect.TerminateRemote(it)) }.orEmpty()
        val staged = job.stagedPath?.let { listOf(Effect.DeleteStagedFile(it)) }.orEmpty()
        return Transition(
            job.copy(state = UploadState.CANCELED, ownerToken = null, updatedAt = now,
                     remoteTerminated = job.uploadUrl == null),
            listOf(Effect.CancelWorker(job.id), Effect.ReleaseReservation, Effect.ReleaseLease) +
                terminate + staged + emit(job.id, UploadState.CANCELED),
        )
    }

    private fun emit(id: String, s: UploadState) = Effect.Emit(id, s)
    private fun t(job: UploadJob, vararg effects: Effect) = Transition(job, effects.toList())

    /** Unexpected pairs are logged by the caller, never thrown. A machine that crashes on a
     *  surprising event is a machine that loses uploads in the field. */
    private fun noop(job: UploadJob) = Transition(job, emptyList())
}
