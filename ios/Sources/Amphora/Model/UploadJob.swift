import Foundation

/// Durable record of one upload. Mirrors `dev.amphora.model.UploadJob` field for field.
///
/// This struct is the only place `uploadUrl` is stored on the device. tusd has no enumeration
/// endpoint, so losing it orphans the server-side resource permanently.
public struct UploadJob: Equatable, Codable, Sendable {
    public let id: String
    public var groupId: String?

    // MARK: source
    public var sourceKind: SourceKind
    public var sourceUri: String
    /// Non-null only when a copy was unavoidable. Prefer streaming.
    public var stagedPath: String?
    public var sizeBytes: Int64
    public var contentType: String
    /// hash(uri, size, mtime, volume) — deliberately not a content hash.
    public var fingerprint: String

    // MARK: remote
    public var endpoint: String
    public var uploadUrl: String?
    public var uploadExpiresAt: Date?
    public var metadata: [String: String]

    // MARK: state
    public var state: UploadState
    public var pauseReason: PauseReason?
    public var blockReason: BlockReason?
    public var errorClass: ErrorClass?
    public var errorDetail: String?

    // MARK: progress
    /// Display hint only. `serverOffset` is the authority (state machine I1).
    public var bytesTransferred: Int64
    public var serverOffset: Int64
    public var serverOffsetAt: Date?

    // MARK: scheduling
    public var attemptCount: Int
    public var nextAttemptAt: Date?
    public var reservedBytes: Int64

    // MARK: single-runner lease (state machine I8)
    public var ownerToken: String?
    public var leaseExpiresAt: Date?

    // MARK: iOS-specific task binding
    //
    // A background `URLSession` recreates its task objects after relaunch, so the object identity
    // is gone — but `taskIdentifier` and `originalRequest.url` are preserved, and `taskDescription`
    // survives as a plain string. We set `taskDescription = id` and persist `taskIdentifier` here,
    // then match on either. This pair is what makes the adopt path in `Reconciler` possible.
    public var taskIdentifier: Int?
    public var sessionIdentifier: String?

    public var policy: UploadPolicy
    public var remoteTerminated: Bool

    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var schemaVersion: Int

    public init(id: String, groupId: String?, sourceKind: SourceKind, sourceUri: String, stagedPath: String?, sizeBytes: Int64,
                contentType: String, fingerprint: String, endpoint: String, uploadUrl: String?, uploadExpiresAt: Date?,
                metadata: [String: String], state: UploadState, pauseReason: PauseReason?, blockReason: BlockReason?,
                errorClass: ErrorClass?, errorDetail: String?, bytesTransferred: Int64, serverOffset: Int64,
                serverOffsetAt: Date?, attemptCount: Int, nextAttemptAt: Date?, reservedBytes: Int64, ownerToken: String?,
                leaseExpiresAt: Date?, taskIdentifier: Int?, sessionIdentifier: String?, policy: UploadPolicy,
                remoteTerminated: Bool, createdAt: Date, updatedAt: Date, completedAt: Date?, schemaVersion: Int) {
        self.id = id; self.groupId = groupId; self.sourceKind = sourceKind; self.sourceUri = sourceUri; self.stagedPath = stagedPath
        self.sizeBytes = sizeBytes; self.contentType = contentType; self.fingerprint = fingerprint; self.endpoint = endpoint
        self.uploadUrl = uploadUrl; self.uploadExpiresAt = uploadExpiresAt; self.metadata = metadata; self.state = state
        self.pauseReason = pauseReason; self.blockReason = blockReason; self.errorClass = errorClass; self.errorDetail = errorDetail
        self.bytesTransferred = bytesTransferred; self.serverOffset = serverOffset; self.serverOffsetAt = serverOffsetAt
        self.attemptCount = attemptCount; self.nextAttemptAt = nextAttemptAt; self.reservedBytes = reservedBytes
        self.ownerToken = ownerToken; self.leaseExpiresAt = leaseExpiresAt; self.taskIdentifier = taskIdentifier
        self.sessionIdentifier = sessionIdentifier; self.policy = policy; self.remoteTerminated = remoteTerminated
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.completedAt = completedAt; self.schemaVersion = schemaVersion
    }

    public var isTerminal: Bool { state.isTerminal }
    public var remaining: Int64 { max(0, sizeBytes - serverOffset) }

    public static let schemaVersion = 1
}

public enum SourceKind: String, Codable, Sendable {
    case file
    /// A `PHAsset`. Always needs an export, and therefore always needs a storage reservation.
    case photosAsset
    case securityScoped
    case stagedCopy
}

public enum UploadState: String, Codable, Sendable {
    case pending, preparing, creating, uploading
    case paused      // user intent — sticky, never auto-resumes
    case blocked     // environmental gate — auto-resumes, never surfaced as an error
    case retryWait   // backoff deadline
    case finalizing
    case recovering  // the launch reconciler is joining this row against getAllTasks()
    case completed, failed, canceled
    case expired     // remote resource gone; restartable from zero if the source survives

    public var isTerminal: Bool { self == .completed || self == .failed || self == .canceled }
    public var isActive: Bool {
        self == .preparing || self == .creating || self == .uploading || self == .finalizing
    }
}

public enum PauseReason: String, Codable, Sendable { case user }

/// All of these auto-resume when the gate clears. None is shown to the user as an error.
public enum BlockReason: String, Codable, Sendable {
    case networkUnavailable
    case networkDisallowed
    case storageLow
    case powerLow
    case concurrencyLimit
    /// Pre-iOS 17 only: a background resume needs a staged remainder file we could not afford.
    /// See docs/reference/ios-background-transfer.md §4.
    case remainderStagingDenied
}

public enum ErrorClass: String, Codable, Sendable {
    case transient, auth, protocolError, fatal, local, sourceGone, protocolVersion
}

public struct UploadPolicy: Equatable, Codable, Sendable {
    public init(allowsExpensiveNetwork: Bool = true, allowsConstrainedNetwork: Bool = false, requiresCharging: Bool = false,
                maxAttempts: Int = 12, priority: Int = 0, isDiscretionary: Bool = true) {
        self.allowsExpensiveNetwork = allowsExpensiveNetwork; self.allowsConstrainedNetwork = allowsConstrainedNetwork
        self.requiresCharging = requiresCharging; self.maxAttempts = maxAttempts; self.priority = priority; self.isDiscretionary = isDiscretionary
    }

    public var allowsExpensiveNetwork: Bool = true
    public var allowsConstrainedNetwork: Bool = false   // respect Low Data Mode by default
    public var requiresCharging: Bool = false
    public var maxAttempts: Int = 12
    public var priority: Int = 0
    /// Maps to `URLSessionConfiguration.isDiscretionary`. Ship `true`; force `false` in debug or
    /// the system may defer uploads for hours and nothing is testable.
    public var isDiscretionary: Bool = true
}
