package dev.amphora

import android.content.Context
import dev.amphora.core.ReconcileReport
import dev.amphora.core.Reconciler
import dev.amphora.core.UploadEngine
import dev.amphora.governor.NetworkPolicy
import dev.amphora.model.UploadJob
import dev.amphora.store.UploadDao
import kotlinx.coroutines.flow.Flow

/**
 * Public API. The React Native TurboModule and any native Android host both bind to this.
 *
 * The contract that matters: [ready] resolves only after reconciliation has run, so a caller
 * that awaits it and then calls [jobs] sees a registry already joined against WorkManager —
 * every surviving upload found, adopted or recovered, and every one of them cancelable.
 */
class AmphoraUploader internal constructor(
    private val context: Context,
    private val dao: UploadDao,
    private val engine: UploadEngine,
    private val reconciler: Reconciler,
) {

    /** Completes when the launch reconciler has finished. Idempotent. */
    suspend fun ready(): ReconcileReport = engine.awaitReady()

    // --- discovery ------------------------------------------------------------

    fun jobs(): Flow<List<UploadJob>> = dao.observeAll()

    suspend fun job(id: String): UploadJob? = dao.get(id)

    // --- commands -------------------------------------------------------------

    /** Returns the client-generated job id immediately; the row is durable before this returns. */
    suspend fun enqueue(request: UploadRequest): String = engine.enqueue(request)

    suspend fun pause(id: String) = engine.pause(id)

    suspend fun resume(id: String) = engine.resume(id)

    /** Works on a job this process has never seen running — the upload URL was persisted before
     *  the first byte, so the remote resource is always reclaimable. */
    suspend fun cancel(id: String) = engine.cancel(id)

    suspend fun retry(id: String) = engine.retry(id)

    companion object {
        @Volatile private var instance: AmphoraUploader? = null

        fun get(context: Context): AmphoraUploader =
            instance ?: synchronized(this) {
                instance ?: AmphoraGraph.of(context.applicationContext).uploader.also { instance = it }
            }
    }
}

data class UploadRequest(
    val sourceUri: String,
    val endpoint: String,
    val contentType: String,
    val metadata: Map<String, String> = emptyMap(),
    val groupId: String? = null,
    val networkPolicy: NetworkPolicy = NetworkPolicy.ANY,
    val requiresCharging: Boolean = false,
    val maxAttempts: Int = 12,
    val priority: Int = 0,
    /** Override when the host app can supply something stronger than (uri, size, mtime). */
    val fingerprint: String? = null,
)
