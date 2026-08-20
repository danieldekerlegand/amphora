import Foundation

/// Public API. The React Native TurboModule and any native iOS host both bind to this.
///
/// The contract that matters: `ready()` resolves only after reconciliation has run, so a caller
/// that awaits it and then calls `jobs()` sees a registry already joined against the background
/// session — every surviving upload found, adopted or recovered, and every one cancelable.
public actor AmphoraUploader {

    public static let shared = AmphoraUploader()

    private var engine: (any UploadEngine)?
    private var sessionManager: BackgroundSessionManager?
    private var store: (any UploadStore)?

    public init() {}

    // MARK: - Lifecycle

    /// Call from `application(_:didFinishLaunchingWithOptions:)`, before anything else.
    ///
    /// This is not a convention, it is a requirement: iOS may relaunch the app specifically to
    /// deliver background-session events, and if the session and its delegate do not exist by the
    /// time those events are replayed, they are lost and the transfers stall silently.
    public func configure(
        store: any UploadStore,
        emitter: any EventEmitter = NoopEventEmitter(),
        tokenProvider: @escaping @Sendable () async -> String? = { nil }
    ) async {
        guard self.store == nil else { return }

        let storage = StorageGovernor()
        let network = NetworkGovernor()
        await network.start()
        let sources = SourceResolver(storage: storage)
        let sink = EventSinkProxy()
        let progress = ProgressCoalescer { [emitter] jobId, sent, total in
            emitter.progress(jobId: jobId, bytesTransferred: sent, total: total)
        }
        let session = BackgroundSessionManager(events: sink, progress: progress)
        let transport = TransportSelector.select(
            session: session, storage: storage, tokenProvider: tokenProvider
        )
        let engine = DefaultUploadEngine(
            store: store,
            sessionManager: session,
            transport: transport,
            storage: storage,
            network: network,
            sources: sources,
            emitter: emitter
        )
        sink.install(engine)
        let reconciler = Reconciler(
            store: store,
            sessionManager: session,
            transport: transport,
            engine: engine,
            storage: storage
        )

        self.store = store
        self.sessionManager = session
        self.engine = engine
        Task {
            let report = await reconciler.reconcile()
            await engine.completeReady(report)
        }
    }

    /// Completes when the launch reconciler has finished. Idempotent; safe to await from
    /// several call sites.
    @discardableResult
    public func ready() async -> ReconcileReport {
        guard let engine else { return ReconcileReport(adopted: 0, recovered: 0, expired: 0, failed: 0, orphanedFilesRemoved: 0) }
        return await engine.awaitReady()
    }

    /// Bridge for `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    ///
    /// Not optional. If the stored handler is never invoked, iOS first deprioritises and then
    /// stops relaunching the app for background events — the uploads do not fail loudly, they
    /// simply stop making progress, which is far harder to diagnose.
    public func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundSessionManager.sessionIdentifier else {
            completionHandler()
            return
        }
        sessionManager?.setSystemCompletionHandler(completionHandler)
    }

    // MARK: - Discovery

    public func jobs() async throws -> [UploadJob] {
        try await store?.all() ?? []
    }

    public func job(id: String) async throws -> UploadJob? {
        try await store?.get(id: id)
    }

    // MARK: - Commands

    /// Returns the client-generated job id immediately; the row is durable before this returns.
    public func enqueue(_ request: UploadRequest) async throws -> String {
        guard let engine else { throw AmphoraError.notConfigured }
        return try await engine.enqueue(request)
    }

    public func pause(id: String) async { await engine?.pause(id: id) }
    public func resume(id: String) async { await engine?.resume(id: id) }

    /// Works on a job this process has never seen running — the upload URL was persisted before
    /// the first byte, so the remote resource is always reclaimable.
    public func cancel(id: String) async { await engine?.cancel(id: id) }
    public func retry(id: String) async { await engine?.retry(id: id) }
}

public enum AmphoraError: Error {
    case notConfigured
}

/// Default sink for hosts that only need the durable command and query API.
public struct NoopEventEmitter: EventEmitter {
    public init() {}
    public func stateChanged(_ job: UploadJob) {}
    public func progress(jobId: String, bytesTransferred: Int64, total: Int64) {}
}

/// Breaks the session/engine construction cycle. The session must exist before the engine so it can
/// receive launch-time callbacks, while the session's delegate needs the engine as its event sink.
private final class EventSinkProxy: UploadEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var target: (any UploadEventSink)?

    func install(_ target: any UploadEventSink) {
        lock.lock()
        self.target = target
        lock.unlock()
    }

    func send(jobId: String, event: UploadEvent) {
        lock.lock()
        let target = self.target
        lock.unlock()
        target?.send(jobId: jobId, event: event)
    }

    func storeResumeData(jobId: String, data: Data) {
        lock.lock()
        let target = self.target
        lock.unlock()
        target?.storeResumeData(jobId: jobId, data: data)
    }

    func noteNativeResumeSupported(jobId: String) {
        lock.lock()
        let target = self.target
        lock.unlock()
        target?.noteNativeResumeSupported(jobId: jobId)
    }
}
