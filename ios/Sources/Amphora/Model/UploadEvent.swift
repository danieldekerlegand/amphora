import Foundation

/// Inputs to the state machine. Mirrors `dev.amphora.model.UploadEvent`.
public enum UploadEvent: Equatable, Sendable {

    // MARK: commands (always valid to issue; may be no-ops)
    case schedule, pause, resume, cancel, retry

    // MARK: transport signals
    case sourceResolved(sizeBytes: Int64, fingerprint: String, stagedPath: String?)
    case sourceMissing
    case remoteCreated(uploadUrl: String, expiresAt: Date?)
    case offsetAdvanced(serverOffset: Int64)
    case transportComplete
    case serverAck
    case transportError(ErrorClass, detail: String?)
    case gone
    case offsetDiverged(serverOffset: Int64)

    // MARK: environment
    case blocked(BlockReason)
    case gateCleared
    case deadlineReached
    case attemptsExhausted
    case spaceDenied(needed: Int64)
    case processStart
}

/// A transition is a new row plus the side effects the caller must perform.
/// Keeping effects declarative keeps the machine pure and therefore testable.
public struct Transition: Sendable {
    public let job: UploadJob
    public let effects: [Effect]
}

public enum Effect: Equatable, Sendable {
    case acquireLease
    case releaseLease
    case reserveSpace(bytes: Int64)
    case releaseReservation
    case deleteStagedFile(path: String)
    case headBeforeResume
    case terminateRemote(uploadUrl: String)
    case startTransfer(jobId: String)
    case cancelTransfer(jobId: String)
    case scheduleRetry(at: Date)
    case emit(jobId: String, state: UploadState)
}
