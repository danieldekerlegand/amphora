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

    private init() {}

    // MARK: - Lifecycle

    /// Call from `application(_:didFinishLaunchingWithOptions:)`, before anything else.
    ///
    /// This is not a convention, it is a requirement: iOS may relaunch the app specifically to
    /// deliver background-session events, and if the session and its delegate do not exist by the
    /// time those events are replayed, they are lost and the transfers stall silently.
    public func configure(store: any UploadStore) async {
        guard self.store == nil else { return }
        // TODO(impl): build the graph — session manager, governors, transport, engine, reconciler.
        self.store = store
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
