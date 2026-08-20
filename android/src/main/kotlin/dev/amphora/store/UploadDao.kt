package dev.amphora.store

import androidx.room.*
import dev.amphora.model.UploadJob
import dev.amphora.model.UploadState
import kotlinx.coroutines.flow.Flow

@Dao
interface UploadDao {

    @Query("SELECT * FROM upload_job WHERE id = :id")
    suspend fun get(id: String): UploadJob?

    @Query("SELECT * FROM upload_job ORDER BY createdAt DESC")
    fun observeAll(): Flow<List<UploadJob>>

    /** The reconciler's working set: everything not durably finished. */
    @Query("SELECT * FROM upload_job WHERE state NOT IN ('COMPLETED','FAILED','CANCELED')")
    suspend fun unfinished(): List<UploadJob>

    @Query("SELECT * FROM upload_job WHERE state = :state")
    suspend fun inState(state: UploadState): List<UploadJob>

    /** Cancelations whose DELETE never reached the server. Retried opportunistically. */
    @Query("SELECT * FROM upload_job WHERE state = 'CANCELED' AND remoteTerminated = 0")
    suspend fun pendingTerminations(): List<UploadJob>

    @Query("SELECT stagedPath FROM upload_job WHERE stagedPath IS NOT NULL")
    suspend fun liveStagedPaths(): List<String>

    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(job: UploadJob)

    @Update
    suspend fun update(job: UploadJob)

    /**
     * Compare-and-set on the lease. Returns rows affected; 0 means another runner holds it.
     * This is the enforcement point for state-machine I8 — a re-enqueued Worker racing a
     * surviving runner must lose here rather than double-PATCH the same upload URL.
     */
    @Query("""
        UPDATE upload_job SET ownerToken = :token, leaseExpiresAt = :expiresAt, updatedAt = :now
        WHERE id = :id AND (ownerToken IS NULL OR ownerToken = :token OR leaseExpiresAt < :now)
    """)
    suspend fun tryAcquireLease(id: String, token: String, expiresAt: Long, now: Long): Int

    @Query("UPDATE upload_job SET ownerToken = NULL WHERE id = :id AND ownerToken = :token")
    suspend fun releaseLease(id: String, token: String)

    @Query("UPDATE upload_job SET leaseExpiresAt = :expiresAt WHERE id = :id AND ownerToken = :token")
    suspend fun renewLease(id: String, token: String, expiresAt: Long)

    @Query("UPDATE upload_job SET ownerToken = NULL WHERE leaseExpiresAt < :now")
    suspend fun breakStaleLeases(now: Long)

    /** Completed rows are retained, not deleted — "did it upload last Tuesday?" is a real question. */
    @Query("DELETE FROM upload_job WHERE state = 'COMPLETED' AND completedAt < :before")
    suspend fun pruneCompleted(before: Long)
}
