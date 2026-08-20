import Foundation
import os

/// The join between the two registries.
///
/// Our store says what *should* be happening. The background `URLSession` — whose tasks survive
/// app termination entirely — says what *is*. Reconciliation is the intersection, and it is the
/// whole answer to "the user closed the app, reopened it, and expects to find their upload".
///
/// Runs once per process start, before the host app is told the module is ready.
/// See docs/reference/persistence-and-recovery.md §5.
public actor Reconciler {

    private let log = Logger(subsystem: "dev.amphora", category: "reconciler")
    private let store: any UploadStore
    private let sessionManager: BackgroundSessionManager
    private let transport: any UploadTransport
    private let engine: any UploadEngine
    private let storage: StorageGovernor
    private let now: @Sendable () -> Date

    public init(
        store: any UploadStore,
        sessionManager: BackgroundSessionManager,
        transport: any UploadTransport,
        engine: any UploadEngine,
        storage: StorageGovernor,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.sessionManager = sessionManager
        self.transport = transport
        self.engine = engine
        self.storage = storage
        self.now = now
    }

    public func reconcile() async -> ReconcileReport {
        var adopted = 0, recovered = 0, expired = 0, failed = 0

        // 1–2. Working set, and leases held by a process that no longer exists.
        try? await store.breakStaleLeases(asOf: now())
        let unfinished = (try? await store.unfinished()) ?? []

        // 3. What is genuinely still running? On iOS this is the strong case: tasks survive
        //    termination, so a job we left mid-transfer is very often still going.
        let live = await sessionManager.liveTasks()
        let liveByJob = Dictionary(uniqueKeysWithValues: live.map { ($0.jobId, $0) })

        for job in unfinished {
            if let task = liveByJob[job.id], task.state == .running || task.state == .suspended {
                // ADOPT. Do not restart: a live task plus a fresh one is two writers on one upload
                // URL, which corrupts silently. The lease (I8) would catch it, but not racing in
                // the first place is cheaper and avoids a wasted round trip.
                adopted += 1
                try? await store.update(id: job.id) { $0.taskIdentifier = task.taskIdentifier }
                log.debug("adopted live task for job \(job.id)")
                continue
            }

            switch job.state {
            case .paused:
                continue                                   // sticky by design
            case .blocked:
                await engine.reevaluateGates(job)
            default:
                switch await recover(job) {
                case .expired: expired += 1
                case .failed: failed += 1
                case .resumable: recovered += 1
                case .deferred: break
                }
            }
        }

        // 5. Crash-path cleanup (state machine I5).
        let livePaths = Set((try? await store.liveStagedPaths()) ?? [])
        let orphans = (try? await storage.collectOrphans(liveStagedPaths: livePaths)) ?? 0
        await retryPendingTerminations()

        return ReconcileReport(
            adopted: adopted, recovered: recovered, expired: expired,
            failed: failed, orphanedFilesRemoved: orphans
        )
    }

    private func recover(_ job: UploadJob) async -> Recovery {
        await engine.dispatch(jobId: job.id, event: .processStart)      // → .recovering

        // a. Is the source still there and unchanged?
        guard await engine.sourceIsIntact(job) else {
            await engine.dispatch(jobId: job.id, event: .sourceMissing)
            return .failed
        }
        // b. Never created remotely — nothing to resume, start clean.
        guard let uploadUrl = job.uploadUrl else {
            await engine.dispatch(jobId: job.id, event: .retry)
            return .resumable
        }
        // c. Server-side lifetime elapsed.
        if let expiresAt = job.uploadExpiresAt, expiresAt < now() {
            await engine.dispatch(jobId: job.id, event: .gone)
            return .expired
        }
        // d. Ask the only authority there is.
        do {
            let head = try await transport.head(uploadUrl: uploadUrl)
            if head.offset < job.serverOffset {              // I7: never resume downward
                await engine.dispatch(jobId: job.id, event: .offsetDiverged(serverOffset: head.offset))
                return .expired
            }
            await engine.dispatch(jobId: job.id, event: .offsetAdvanced(serverOffset: head.offset))
            return .resumable
        } catch {
            // An offline launch must still list and cancel jobs; only *resuming* needs network.
            await engine.dispatch(jobId: job.id, event: .blocked(.networkUnavailable))
            return .deferred
        }
    }

    /// Cancelations whose DELETE never landed, because the device was offline at the time.
    private func retryPendingTerminations() async {
        let pending = (try? await store.pendingTerminations()) ?? []
        for job in pending {
            guard let url = job.uploadUrl else { continue }
            if (try? await transport.terminate(uploadUrl: url)) != nil {
                try? await store.update(id: job.id) { $0.remoteTerminated = true }
            }
        }
    }

    private enum Recovery { case resumable, expired, failed, deferred }
}

public struct ReconcileReport: Sendable, Codable {
    public let adopted: Int
    public let recovered: Int
    public let expired: Int
    public let failed: Int
    public let orphanedFilesRemoved: Int
}
