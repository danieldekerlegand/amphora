import Foundation
import os

/// Applies `UploadStateMachine` transitions and performs the effects they declare.
///
/// The split is the point: the machine decides, the engine acts. Nothing here may contain policy —
/// if a decision appears in this file that is not in the machine, the two platforms have begun to
/// drift and the conformance vectors will not catch it.
///
/// Note how much smaller this is than its Kotlin sibling. That is not tidier code, it is iOS doing
/// the work: the system owns retry scheduling, connectivity waiting, and (on 17+) offset
/// management, so the engine mostly starts tasks and records what the delegate reports.
public actor DefaultUploadEngine: UploadEngine {

    private let log = Logger(subsystem: "dev.amphora", category: "engine")
    private let store: any UploadStore
    private let sessionManager: BackgroundSessionManager
    private let transport: any UploadTransport
    private let storage: StorageGovernor
    private let network: NetworkGovernor
    private let sources: SourceResolver
    private let emitter: any EventEmitter
    private let now: @Sendable () -> Date

    private var readyContinuations: [CheckedContinuation<ReconcileReport, Never>] = []
    private var readyReport: ReconcileReport?
    /// Jobs that never saw a `104`. They cannot rely on OS-managed resumption.
    private var nativeResumeUnavailable: Set<String> = []

    public init(
        store: any UploadStore,
        sessionManager: BackgroundSessionManager,
        transport: any UploadTransport,
        storage: StorageGovernor,
        network: NetworkGovernor,
        sources: SourceResolver,
        emitter: any EventEmitter,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.sessionManager = sessionManager
        self.transport = transport
        self.storage = storage
        self.network = network
        self.sources = sources
        self.emitter = emitter
        self.now = now
    }

    // MARK: - Readiness

    public func awaitReady() async -> ReconcileReport {
        if let readyReport { return readyReport }
        return await withCheckedContinuation { readyContinuations.append($0) }
    }

    public func completeReady(_ report: ReconcileReport) {
        readyReport = report
        readyContinuations.forEach { $0.resume(returning: report) }
        readyContinuations.removeAll()
    }

    // MARK: - Commands

    public func enqueue(_ request: UploadRequest) async throws -> String {
        let probe = try await sources.probe(request.sourceUri)
        let job = UploadJob(
            id: UUID().uuidString,
            groupId: request.groupId,
            sourceKind: probe.kind,
            sourceUri: request.sourceUri,
            stagedPath: nil,
            sizeBytes: probe.sizeBytes,
            contentType: request.contentType,
            fingerprint: request.fingerprint ?? probe.fingerprint,
            endpoint: request.endpoint,
            uploadUrl: nil,
            uploadExpiresAt: nil,
            metadata: request.metadata,
            state: .pending,
            pauseReason: nil, blockReason: nil, errorClass: nil, errorDetail: nil,
            bytesTransferred: 0, serverOffset: 0, serverOffsetAt: nil,
            attemptCount: 0, nextAttemptAt: nil, reservedBytes: 0,
            ownerToken: nil, leaseExpiresAt: nil,
            taskIdentifier: nil, sessionIdentifier: BackgroundSessionManager.sessionIdentifier,
            policy: request.policy,
            remoteTerminated: true,
            createdAt: now(), updatedAt: now(), completedAt: nil,
            schemaVersion: UploadJob.schemaVersion
        )
        // Durable before we return the id, so a crash on the very next line still leaves a job the
        // reconciler can find.
        try await store.insert(job)
        emitter.stateChanged(job)
        await dispatch(jobId: job.id, event: .schedule)
        return job.id
    }

    public func pause(id: String) async { await dispatch(jobId: id, event: .pause) }
    public func resume(id: String) async { await dispatch(jobId: id, event: .resume) }
    public func cancel(id: String) async { await dispatch(jobId: id, event: .cancel) }
    public func retry(id: String) async { await dispatch(jobId: id, event: .retry) }

    // MARK: - The reduce loop
    //
    // Actor isolation gives us the serialisation the Kotlin engine needs an explicit mutex for:
    // no two events can interleave a read-modify-write on the same row.

    public func dispatch(jobId: String, event: UploadEvent) async {
        guard let current = try? await store.get(id: jobId) else { return }

        let transition = UploadStateMachine.reduce(current, event, now: now())
        if transition.job != current {
            try? await store.update(id: jobId) { $0 = transition.job }
        } else if transition.effects.isEmpty {
            // Logged, never thrown. A machine that crashes on a surprising event is a machine that
            // loses uploads in the field.
            log.debug("no-op: \(current.state.rawValue) + \(String(describing: event))")
            return
        }

        for effect in transition.effects {
            await run(effect, on: transition.job)
        }
    }

    private func run(_ effect: Effect, on job: UploadJob) async {
        switch effect {
        case .acquireLease, .releaseLease:
            break   // iOS runs one task per job in a system-owned session; the lease guards the
                    // adopt path in the reconciler rather than concurrent runners here.

        case .startTransfer:
            await startTransfer(job)

        case .cancelTransfer:
            await sessionManager.cancel(jobId: job.id)

        case let .scheduleRetry(at):
            // No WorkManager equivalent. Background sessions already retry at increasing
            // intervals; this timer only covers explicit backoff while the app is alive.
            let delay = at.timeIntervalSince(now())
            if delay > 0 {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    await self?.dispatch(jobId: job.id, event: .deadlineReached)
                }
            }

        case .reserveSpace:
            break   // performed inline in startTransfer, where the size is actually known

        case .releaseReservation:
            await storage.release(jobId: job.id)

        case let .deleteStagedFile(path):
            try? FileManager.default.removeItem(atPath: path)

        case let .terminateRemote(uploadUrl):
            // Best-effort. Offline, the row keeps remoteTerminated=false and the reconciler retries
            // on a later launch — the resource is never silently abandoned.
            if (try? await transport.terminate(uploadUrl: uploadUrl)) != nil {
                try? await store.update(id: job.id) { $0.remoteTerminated = true }
            }

        case .headBeforeResume:
            break   // startTransfer always HEADs first

        case .emit:
            if let fresh = try? await store.get(id: job.id) {
                emitter.stateChanged(fresh)
            }
        }
    }

    // MARK: - Transfer

    private func startTransfer(_ job: UploadJob) async {
        if let reason = await checkGates(job) {
            await dispatch(jobId: job.id, event: .blocked(reason))
            return
        }
        guard await sourceIsIntact(job) else {
            await dispatch(jobId: job.id, event: .sourceMissing)
            return
        }

        var current = job

        // Create on first run. I2: the URL is persisted by the transition before any byte moves.
        if current.uploadUrl == nil {
            do {
                // Stage BEFORE the remote exists — the order of `prepare()` in the Kotlin engine.
                // A `ph://` asset cannot be seeked, so it must become a real file first; doing it
                // after `create` would orphan a server resource whenever the reservation is
                // refused. The reducer, not this method, records the path and flips `sourceKind`.
                let staged: URL?
                do {
                    staged = try await sources.stageIfRequired(current)
                } catch let TransportError.remainderStagingDenied(needed) {
                    // Kotlin's `StorageReservationDenied -> SpaceDenied`, typed so the machine
                    // blocks instead of creating remotely. Every other staging failure falls
                    // through to the transport-error catch below, as it does there.
                    await dispatch(jobId: job.id, event: .spaceDenied(needed: needed))
                    return
                } catch StorageError.stagingDenied {
                    await dispatch(jobId: job.id, event: .spaceDenied(needed: current.sizeBytes))
                    return
                }
                await dispatch(jobId: job.id, event: .sourceResolved(
                    sizeBytes: current.sizeBytes, fingerprint: current.fingerprint, stagedPath: staged?.path
                ))
                let created = try await transport.create(
                    endpoint: current.endpoint, sizeBytes: current.sizeBytes, metadata: current.metadata
                )
                await dispatch(jobId: job.id, event: .remoteCreated(
                    uploadUrl: created.uploadUrl, expiresAt: created.expiresAt
                ))
            } catch {
                await dispatch(jobId: job.id, event: .transportError(classify(error), detail: "\(error)"))
                return
            }
            guard let refreshed = try? await store.get(id: job.id) else { return }
            current = refreshed
        }

        guard let uploadUrl = current.uploadUrl else { return }

        // I1: the server's offset, never our remembered one.
        let offset: Int64
        do {
            offset = try await transport.head(uploadUrl: uploadUrl).offset
        } catch TransportError.gone {
            await dispatch(jobId: job.id, event: .gone)
            return
        } catch {
            await dispatch(jobId: job.id, event: .transportError(classify(error), detail: "\(error)"))
            return
        }

        if offset < current.serverOffset {
            await dispatch(jobId: job.id, event: .offsetDiverged(serverOffset: offset))
            return
        }
        if offset > current.sizeBytes {
            await dispatch(jobId: job.id, event: .transportError(.protocolError, detail: "\(TransportError.unexpectedOffset(actual: offset))"))
            return
        }
        if offset >= current.sizeBytes {
            await dispatch(jobId: job.id, event: .transportComplete)
            await dispatch(jobId: job.id, event: .serverAck)
            return
        }

        do {
            // Hands the file to the background session and returns. Completion arrives through the
            // delegate, possibly in a future process — which is the whole point.
            let handle = try await transport.startTransfer(job: current, from: offset)
            try? await store.update(id: job.id) {
                $0.taskIdentifier = handle.taskIdentifier
                $0.stagedPath = handle.stagedRemainderPath ?? $0.stagedPath
            }
        } catch let TransportError.remainderStagingDenied(needed) {
            // Pre-iOS-17 only. Wait for space rather than corrupting.
            log.notice("job \(job.id) needs \(needed) bytes to stage a remainder; blocking")
            await dispatch(jobId: job.id, event: .blocked(.remainderStagingDenied))
        } catch {
            await dispatch(jobId: job.id, event: .transportError(classify(error), detail: "\(error)"))
        }
    }

    // MARK: - Gates

    private func checkGates(_ job: UploadJob) async -> BlockReason? {
        // The system already waits for connectivity on background sessions, so this is only about
        // the decisions iOS will not make for us: cellular and Low Data Mode.
        if !(await network.permits(job.policy)) {
            return await network.status() == .unavailable ? .networkUnavailable : .networkDisallowed
        }
        // Only staged jobs can be defeated by low storage; a streamed upload needs no headroom.
        if job.stagedPath != nil, await storage.sample() == .critical {
            return .storageLow
        }
        return nil
    }

    public func reevaluateGates(_ job: UploadJob) async {
        if await checkGates(job) == nil {
            await dispatch(jobId: job.id, event: .gateCleared)
        }
    }

    public func sourceIsIntact(_ job: UploadJob) async -> Bool {
        await sources.isIntact(job)
    }

    private func classify(_ error: Error) -> ErrorClass {
        if let transportError = error as? TransportError { return transportError.errorClass }
        if let urlError = error as? URLError {
            return urlError.code == .userAuthenticationRequired ? .auth : .transient
        }
        return .transient
    }
}

// MARK: - Event sink

extension DefaultUploadEngine: UploadEventSink {

    public nonisolated func send(jobId: String, event: UploadEvent) {
        Task { await dispatch(jobId: jobId, event: event) }
    }

    public nonisolated func storeResumeData(jobId: String, data: Data) {
        Task { try? await store.storeResumeData(id: jobId, data: data) }
    }

    public nonisolated func noteNativeResumeSupported(jobId: String) {
        Task { await markNativeResumeSupported(jobId) }
    }

    private func markNativeResumeSupported(_ jobId: String) {
        nativeResumeUnavailable.remove(jobId)
    }
}

/// Where host-facing events go. Implemented by the RN bridge and by native iOS hosts.
public protocol EventEmitter: Sendable {
    func stateChanged(_ job: UploadJob)
    func progress(jobId: String, bytesTransferred: Int64, total: Int64)
}
