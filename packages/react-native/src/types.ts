/**
 * Shared types for the Amphora RN binding.
 *
 * These mirror the Kotlin/Swift models exactly. Divergence here is the most likely source of
 * subtle cross-platform bugs, so the enums are generated from the same source of truth as the
 * native ones rather than hand-maintained. See docs/reference/state-machine.md §1.
 */

export type UploadState =
  | 'PENDING'
  | 'PREPARING'
  | 'CREATING'
  | 'UPLOADING'
  | 'PAUSED'      // user intent — sticky, never auto-resumes
  | 'BLOCKED'     // environmental gate — auto-resumes, never show as an error
  | 'RETRY_WAIT'  // backoff deadline
  | 'FINALIZING'
  | 'RECOVERING'  // launch reconciler is joining this row against the platform task registry
  | 'COMPLETED'
  | 'FAILED'
  | 'CANCELED'
  | 'EXPIRED';    // remote resource gone; restartable from zero if the source survives

export type BlockReason =
  | 'NETWORK_UNAVAILABLE'
  | 'NETWORK_DISALLOWED'
  | 'STORAGE_LOW'
  | 'POWER_LOW'
  | 'FGS_QUOTA_EXHAUSTED'  // Android 15 dataSync 6h/24h budget
  | 'CONCURRENCY_LIMIT';

export type ErrorClass =
  | 'TRANSIENT' | 'AUTH' | 'PROTOCOL' | 'FATAL'
  | 'LOCAL' | 'SOURCE_GONE' | 'PROTOCOL_VERSION';

export interface UploadJob {
  id: string;
  groupId: string | null;
  sourceUri: string;
  sizeBytes: number;
  contentType: string;
  state: UploadState;
  blockReason: BlockReason | null;
  errorClass: ErrorClass | null;
  errorDetail: string | null;
  /** Display hint. The server's offset is the authority; this trails it. */
  bytesTransferred: number;
  attemptCount: number;
  nextAttemptAt: number | null;
  createdAt: number;
  updatedAt: number;
  completedAt: number | null;
}

export interface UploadRequest {
  sourceUri: string;
  endpoint: string;
  contentType: string;
  metadata?: Record<string, string>;
  groupId?: string;
  networkPolicy?: 'ANY' | 'UNMETERED_ONLY';
  requiresCharging?: boolean;
  maxAttempts?: number;
  priority?: number;
  /** Supply when the host app can do better than (uri, size, mtime) — e.g. an editable source. */
  fingerprint?: string;
}

/** Result of the launch reconciliation, surfaced so a host app can report or log it. */
export interface ReadyReport {
  adopted: number;   // still running natively; re-attached without restarting
  recovered: number; // orphaned but resumable from the server's offset
  expired: number;
  failed: number;
  orphanedFilesRemoved: number;
}

export type AmphoraEvent =
  | { type: 'ready'; report: ReadyReport }
  | { type: 'stateChanged'; job: UploadJob }
  | { type: 'progress'; id: string; bytesTransferred: number; sizeBytes: number }
  | { type: 'completed'; job: UploadJob }
  | { type: 'failed'; job: UploadJob };
