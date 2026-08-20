import Foundation

/// The transition function. Pure: no IO, no clock reads beyond the injected `now`, no async.
///
/// A line-by-line mirror of `dev.amphora.core.UploadStateMachine`. Both run the same conformance
/// vectors (`Tests/Conformance/vectors.json`), which is the only thing that keeps two hand-written
/// ports from quietly disagreeing about, say, whether a 409 is fatal.
///
/// See docs/reference/state-machine.md §2.
public enum UploadStateMachine {

    public static let maxAttempts = 12
    private static let leaseDuration: TimeInterval = 120

    public static func reduce(_ job: UploadJob, _ event: UploadEvent, now: Date) -> Transition {

        // Cancel and processStart are legal from every non-terminal state, so handle them up front
        // rather than repeating them in each branch.
        switch event {
        case .cancel where !job.isTerminal:
            return cancel(job, now)
        case .processStart where !job.isTerminal && job.state != .recovering:
            var j = job
            j.state = .recovering
            j.ownerToken = nil
            j.updatedAt = now
            return t(j)
        default:
            break
        }

        switch job.state {

        case .pending:
            guard case .schedule = event else { return noop(job) }
            var j = job
            j.state = .preparing
            j.updatedAt = now
            j.leaseExpiresAt = now.addingTimeInterval(leaseDuration)
            return t(j, .acquireLease, .emit(jobId: job.id, state: .preparing))

        case .preparing:
            switch event {
            case let .sourceResolved(size, fingerprint, stagedPath):
                var j = job
                j.state = .creating
                j.sizeBytes = size
                j.fingerprint = fingerprint
                j.stagedPath = stagedPath
                if stagedPath != nil { j.sourceKind = .stagedCopy }
                j.updatedAt = now
                return t(j, .emit(jobId: job.id, state: .creating))
            case .sourceMissing:
                return fail(job, .sourceGone, "source no longer readable", now)
            case .spaceDenied:
                return block(job, .storageLow, now)
            case let .transportError(cls, detail):
                return classify(job, cls, detail, now)
            default:
                return noop(job)
            }

        // I2: uploadUrl is persisted here, before a single byte is sent. Violating this orphans a
        // server resource that can never be resumed *or* deleted.
        case .creating:
            switch event {
            case let .remoteCreated(url, expiresAt):
                var j = job
                j.state = .uploading
                j.uploadUrl = url
                j.uploadExpiresAt = expiresAt
                j.remoteTerminated = false
                j.attemptCount = 0
                j.updatedAt = now
                return t(j, .emit(jobId: job.id, state: .uploading))
            case let .transportError(cls, detail): return classify(job, cls, detail, now)
            case let .blocked(reason): return block(job, reason, now)
            case .pause: return pause(job, now)
            default: return noop(job)
            }

        case .uploading:
            switch event {
            // Only ever written from an acked response. I7: never accept a lower offset.
            case let .offsetAdvanced(offset):
                guard offset >= job.serverOffset else { return expire(job, now) }
                var j = job
                j.serverOffset = offset
                j.bytesTransferred = offset
                j.serverOffsetAt = now
                j.updatedAt = now
                return t(j)
            case .transportComplete:
                var j = job
                j.state = .finalizing
                j.updatedAt = now
                return t(j, .emit(jobId: job.id, state: .finalizing))
            case .offsetDiverged, .gone:
                return expire(job, now)
            case let .transportError(cls, detail): return classify(job, cls, detail, now)
            case let .blocked(reason): return block(job, reason, now)
            case .pause: return pause(job, now)
            default: return noop(job)
            }

        case .finalizing:
            switch event {
            case .serverAck:
                var j = job
                j.state = .completed
                j.bytesTransferred = job.sizeBytes
                j.serverOffset = job.sizeBytes
                j.completedAt = now
                j.updatedAt = now
                j.ownerToken = nil
                j.remoteTerminated = true
                var effects: [Effect] = [.releaseReservation, .releaseLease]
                if let staged = job.stagedPath { effects.append(.deleteStagedFile(path: staged)) }
                effects.append(.emit(jobId: job.id, state: .completed))
                return Transition(job: j, effects: effects)
            case let .transportError(cls, detail): return classify(job, cls, detail, now)
            case .gone: return expire(job, now)
            default: return noop(job)
            }

        // All three resume through HEAD, never from a cached local offset (I1).
        case .paused:
            guard case .resume = event else { return noop(job) }
            return resume(job, now)

        case .blocked:
            switch event {
            case .gateCleared, .resume: return resume(job, now)
            case .pause: return pause(job, now)
            case let .blocked(reason):
                var j = job; j.blockReason = reason; j.updatedAt = now
                return t(j)
            default: return noop(job)
            }

        case .retryWait:
            switch event {
            case .deadlineReached: return resume(job, now)
            case .pause: return pause(job, now)
            case let .blocked(reason): return block(job, reason, now)
            default: return noop(job)
            }

        // The reconciler drives this one; it feeds results back as ordinary events.
        case .recovering:
            switch event {
            case .sourceMissing:
                return fail(job, .sourceGone, "source no longer readable", now)
            case let .offsetAdvanced(offset):
                guard offset >= job.serverOffset else { return expire(job, now) }
                var j = job
                j.serverOffset = offset
                j.bytesTransferred = offset
                j.serverOffsetAt = now
                j.updatedAt = now
                if offset >= job.sizeBytes {
                    j.state = .finalizing
                    return t(j, .emit(jobId: job.id, state: .finalizing))
                }
                j.state = .uploading
                return t(j, .startTransfer(jobId: job.id), .emit(jobId: job.id, state: .uploading))
            case .gone: return expire(job, now)
            case let .blocked(reason): return block(job, reason, now)
            case .pause: return pause(job, now)
            case let .transportError(cls, detail): return classify(job, cls, detail, now)
            default: return noop(job)
            }

        case .expired, .failed:
            guard case .retry = event else { return noop(job) }
            var j = job
            j.state = .pending
            j.uploadUrl = nil
            j.uploadExpiresAt = nil
            j.serverOffset = 0
            j.bytesTransferred = 0
            j.attemptCount = 0
            j.errorClass = nil
            j.errorDetail = nil
            j.blockReason = nil
            j.taskIdentifier = nil
            j.updatedAt = now
            return t(j, .startTransfer(jobId: job.id), .emit(jobId: job.id, state: .pending))

        case .completed, .canceled:
            return noop(job)   // I4: absorbing
        }
    }

    // MARK: - helpers

    /// A transport failure that still moved the offset forward does not consume the retry budget.
    /// Without this rule a large upload on flaky Wi-Fi exhausts its attempts while making steady
    /// forward progress — the most common way a technically-correct uploader fails a real user.
    private static func classify(
        _ job: UploadJob, _ cls: ErrorClass, _ detail: String?, _ now: Date
    ) -> Transition {
        switch cls {
        case .fatal, .protocolVersion:
            return fail(job, cls, detail, now)
        case .auth:
            return job.attemptCount == 0
                ? retryWait(job, now, cls, detail)
                : fail(job, .auth, detail, now)
        case .local:
            return block(job, .storageLow, now)
        default:
            return retryWait(job, now, cls, detail)
        }
    }

    private static func retryWait(
        _ job: UploadJob, _ now: Date, _ cls: ErrorClass, _ detail: String?
    ) -> Transition {
        let madeProgress = (job.serverOffsetAt ?? .distantPast) >= job.updatedAt
        let attempts = madeProgress ? job.attemptCount : job.attemptCount + 1
        guard attempts < maxAttempts else { return fail(job, cls, detail, now) }

        let backoff = min(pow(2.0, Double(min(attempts, 8))), 300)
        let at = now.addingTimeInterval(backoff)
        var j = job
        j.state = .retryWait
        j.attemptCount = attempts
        j.nextAttemptAt = at
        j.errorClass = cls
        j.errorDetail = detail
        j.updatedAt = now
        return t(j, .scheduleRetry(at: at), .emit(jobId: job.id, state: .retryWait))
    }

    private static func resume(_ job: UploadJob, _ now: Date) -> Transition {
        var j = job
        j.state = .uploading
        j.pauseReason = nil
        j.blockReason = nil
        j.nextAttemptAt = nil
        j.updatedAt = now
        return t(j, .headBeforeResume, .startTransfer(jobId: job.id),
                 .emit(jobId: job.id, state: .uploading))
    }

    private static func pause(_ job: UploadJob, _ now: Date) -> Transition {
        var j = job
        j.state = .paused
        j.pauseReason = .user
        j.blockReason = nil
        j.ownerToken = nil
        j.updatedAt = now
        return t(j, .cancelTransfer(jobId: job.id), .releaseLease,
                 .emit(jobId: job.id, state: .paused))
    }

    private static func block(_ job: UploadJob, _ reason: BlockReason, _ now: Date) -> Transition {
        var j = job
        j.state = .blocked
        j.blockReason = reason
        j.ownerToken = nil
        j.updatedAt = now
        return t(j, .cancelTransfer(jobId: job.id), .releaseLease,
                 .emit(jobId: job.id, state: .blocked))
    }

    private static func expire(_ job: UploadJob, _ now: Date) -> Transition {
        var j = job
        j.state = .expired
        j.uploadUrl = nil
        j.serverOffset = 0
        j.bytesTransferred = 0
        j.remoteTerminated = true
        j.ownerToken = nil
        j.taskIdentifier = nil
        j.updatedAt = now
        return t(j, .releaseReservation, .releaseLease, .emit(jobId: job.id, state: .expired))
    }

    private static func fail(
        _ job: UploadJob, _ cls: ErrorClass, _ detail: String?, _ now: Date
    ) -> Transition {
        var j = job
        j.state = .failed
        j.errorClass = cls
        j.errorDetail = detail
        j.ownerToken = nil
        j.updatedAt = now
        return t(j, .releaseReservation, .releaseLease, .emit(jobId: job.id, state: .failed))
    }

    private static func cancel(_ job: UploadJob, _ now: Date) -> Transition {
        // I2 pays off here: the URL was persisted before the first byte, so an orphaned job the
        // app has never seen running is still cancelable. Offline, this is retried on next launch.
        var j = job
        j.state = .canceled
        j.ownerToken = nil
        j.updatedAt = now
        j.remoteTerminated = (job.uploadUrl == nil)

        var effects: [Effect] = [.cancelTransfer(jobId: job.id), .releaseReservation, .releaseLease]
        if let url = job.uploadUrl { effects.append(.terminateRemote(uploadUrl: url)) }
        if let staged = job.stagedPath { effects.append(.deleteStagedFile(path: staged)) }
        effects.append(.emit(jobId: job.id, state: .canceled))
        return Transition(job: j, effects: effects)
    }

    private static func t(_ job: UploadJob, _ effects: Effect...) -> Transition {
        Transition(job: job, effects: effects)
    }

    /// Unexpected pairs are logged by the caller, never thrown. A machine that crashes on a
    /// surprising event is a machine that loses uploads in the field.
    private static func noop(_ job: UploadJob) -> Transition {
        Transition(job: job, effects: [])
    }
}
