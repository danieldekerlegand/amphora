package dev.amphora.model

import androidx.room.Entity
import androidx.room.PrimaryKey
import java.util.UUID

/**
 * Durable record of one upload. See docs/reference/persistence-and-recovery.md §2.
 *
 * This row is the only place `uploadUrl` is stored on the device. tusd has no enumeration
 * endpoint, so losing it orphans the server-side resource permanently.
 */
@Entity(tableName = "upload_job")
data class UploadJob(
    @PrimaryKey val id: String = UUID.randomUUID().toString(),
    val groupId: String? = null,

    // --- source ---------------------------------------------------------------
    val sourceKind: SourceKind,
    val sourceUri: String,
    /** Non-null only when a copy was unavoidable. Prefer streaming; see §3. */
    val stagedPath: String? = null,
    val sizeBytes: Long,
    val contentType: String,
    /** hash(uri, size, mtime, volume) — deliberately not a content hash. See §6. */
    val fingerprint: String,

    // --- remote ---------------------------------------------------------------
    val endpoint: String,
    val uploadUrl: String? = null,
    val uploadExpiresAt: Long? = null,
    val metadataJson: String = "{}",

    // --- state ----------------------------------------------------------------
    val state: UploadState = UploadState.PENDING,
    val pauseReason: PauseReason? = null,
    val blockReason: BlockReason? = null,
    val errorClass: ErrorClass? = null,
    val errorDetail: String? = null,

    // --- progress -------------------------------------------------------------
    /** Display hint only. `serverOffset` is the authority (state-machine I1). */
    val bytesTransferred: Long = 0,
    val serverOffset: Long = 0,
    val serverOffsetAt: Long = 0,

    // --- scheduling -----------------------------------------------------------
    val attemptCount: Int = 0,
    val nextAttemptAt: Long? = null,
    val reservedBytes: Long = 0,

    // --- single-runner lease (state-machine I8) -------------------------------
    val ownerToken: String? = null,
    val leaseExpiresAt: Long = 0,

    val policyJson: String = "{}",
    val remoteTerminated: Boolean = true,

    val createdAt: Long,
    val updatedAt: Long,
    val completedAt: Long? = null,
    val schemaVersion: Int = SCHEMA_VERSION,
) {
    val isTerminal: Boolean get() = state.isTerminal
    val remaining: Long get() = (sizeBytes - serverOffset).coerceAtLeast(0)

    companion object { const val SCHEMA_VERSION = 1 }
}

enum class SourceKind { FILE, CONTENT_URI, STAGED_COPY }

enum class UploadState {
    PENDING, PREPARING, CREATING, UPLOADING,
    PAUSED, BLOCKED, RETRY_WAIT,
    FINALIZING, RECOVERING,
    COMPLETED, FAILED, CANCELED, EXPIRED;

    val isTerminal: Boolean get() = this == COMPLETED || this == FAILED || this == CANCELED
    /** EXPIRED is recoverable from offset zero, so it is not terminal. */
    val isActive: Boolean get() = this == PREPARING || this == CREATING || this == UPLOADING || this == FINALIZING
}

enum class PauseReason { USER }

/** All of these auto-resume when the gate clears. None is surfaced to the user as an error. */
enum class BlockReason {
    NETWORK_UNAVAILABLE,
    NETWORK_DISALLOWED,
    STORAGE_LOW,
    POWER_LOW,
    /** Android 15: dataSync FGS exhausted its 6h/24h budget. See platform-constraints.md §2. */
    FGS_QUOTA_EXHAUSTED,
    CONCURRENCY_LIMIT,
}

enum class ErrorClass { TRANSIENT, AUTH, PROTOCOL, FATAL, LOCAL, SOURCE_GONE, PROTOCOL_VERSION }
