package dev.amphora.work

import android.app.ForegroundServiceStartNotAllowedException
import android.content.Context
import androidx.work.*
import dev.amphora.AmphoraGraph
import dev.amphora.model.*
import dev.amphora.governor.NetworkPolicy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * One bounded slice of transfer work.
 *
 * Deliberately *not* "run until the upload finishes". Android 15 caps dataSync foreground
 * services at 6 hours per 24, and WorkManager expects executions on the order of ten minutes.
 * So each execution uploads until a byte or time ceiling, persists the acked offset, and
 * enqueues its successor. A 40 GB upload is a chain of short workers over a durable offset,
 * which is also exactly what makes it survivable across process death.
 *
 * See docs/reference/platform-constraints.md §2.
 */
class UploadWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    private val jobId: String get() = inputData.getString(KEY_JOB_ID)!!
    private val runnerToken = UUID.randomUUID().toString()

    override suspend fun doWork(): Result {
        val deps = AmphoraGraph.of(applicationContext)
        val job = deps.dao.get(jobId) ?: return Result.failure()

        // I8: lose the race rather than double-PATCH. A resurrected worker from a previous
        // process can still be holding a live lease.
        val acquired = deps.dao.tryAcquireLease(
            id = jobId, token = runnerToken,
            expiresAt = deps.clock.now() + LEASE_MS, now = deps.clock.now(),
        )
        if (acquired == 0) return Result.success()

        return try {
            setForeground(deps.notifications.foregroundInfo(job))
            deps.engine.runSlice(
                jobId = jobId,
                runnerToken = runnerToken,
                byteCeiling = SLICE_BYTE_CEILING,
                deadline = deps.clock.now() + SLICE_DURATION_MS,
            ).toWorkResult()
        } catch (e: ForegroundServiceStartNotAllowedException) {
            // Android 15: the 6h/24h dataSync budget is spent. Not an error — the job blocks and
            // resumes when the budget refreshes or the user next foregrounds the app.
            deps.engine.dispatch(jobId, UploadEvent.Blocked(BlockReason.FGS_QUOTA_EXHAUSTED))
            Result.success()
        } finally {
            deps.dao.releaseLease(jobId, runnerToken)
        }
    }

    /**
     * Android 15 calls this when the FGS budget expires mid-run. A few seconds to stop cleanly;
     * failing to is a RemoteServiceException. Persist offset, block the job, get out.
     */
    override fun onStopped() {
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            val deps = AmphoraGraph.of(applicationContext)
            deps.engine.flushOffset(jobId)
            deps.dao.releaseLease(jobId, runnerToken)
        }
    }

    private fun SliceOutcome.toWorkResult(): Result = when (this) {
        SliceOutcome.COMPLETE, SliceOutcome.SLICE_DONE -> Result.success()
        SliceOutcome.RETRY -> Result.retry()
        SliceOutcome.TERMINAL -> Result.failure()
    }

    companion object {
        const val KEY_JOB_ID = "jobId"
        private const val LEASE_MS = 120_000L
        private const val SLICE_BYTE_CEILING = 2L * 1024 * 1024 * 1024
        private const val SLICE_DURATION_MS = 8L * 60 * 1000

        fun tag(jobId: String) = "amphora-job:$jobId"

        /**
         * Constraints are advisory scheduling hints, not the policy. The state machine still
         * decides whether to transfer — WorkManager just avoids waking us pointlessly.
         */
        fun request(jobId: String, policy: NetworkPolicy, requiresCharging: Boolean): OneTimeWorkRequest =
            OneTimeWorkRequestBuilder<UploadWorker>()
                .addTag(tag(jobId))
                .setInputData(workDataOf(KEY_JOB_ID to jobId))
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(
                            if (policy == NetworkPolicy.UNMETERED_ONLY) NetworkType.UNMETERED
                            else NetworkType.CONNECTED
                        )
                        .setRequiresCharging(requiresCharging)
                        .build()
                )
                // KEEP, so re-enqueueing an already-scheduled job is idempotent.
                .build()

        fun enqueue(context: Context, jobId: String, policy: NetworkPolicy, requiresCharging: Boolean) {
            WorkManager.getInstance(context).enqueueUniqueWork(
                tag(jobId), ExistingWorkPolicy.KEEP, request(jobId, policy, requiresCharging),
            )
        }

        fun enqueueDelayed(context: Context, jobId: String, delayMillis: Long) {
            val work = OneTimeWorkRequestBuilder<UploadWorker>()
                .addTag(tag(jobId))
                .setInputData(workDataOf(KEY_JOB_ID to jobId))
                .setInitialDelay(delayMillis.coerceAtLeast(0L), java.util.concurrent.TimeUnit.MILLISECONDS)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                tag(jobId), ExistingWorkPolicy.REPLACE, work,
            )
        }
    }
}

enum class SliceOutcome { COMPLETE, SLICE_DONE, RETRY, TERMINAL }
