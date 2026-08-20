import Foundation

/// Applies `UploadStateMachine` transitions and performs the effects they declare.
///
/// The split is the point: the machine decides, the engine acts. Everything here is IO and
/// therefore untestable-by-inspection, which is exactly why none of it may contain policy.
public protocol UploadEngine: Actor {
    func awaitReady() async -> ReconcileReport

    func enqueue(_ request: UploadRequest) async throws -> String
    func pause(id: String) async
    func resume(id: String) async
    func cancel(id: String) async
    func retry(id: String) async

    /// Feed an event through the machine, persist the new row, run the effects, emit to hosts.
    func dispatch(jobId: String, event: UploadEvent) async

    /// Re-check network/storage/power for a blocked job and unblock if the gate has cleared.
    func reevaluateGates(_ job: UploadJob) async

    /// Cheap existence + fingerprint check. Deliberately not a content hash.
    func sourceIsIntact(_ job: UploadJob) async -> Bool
}

/// Where session-delegate callbacks land. Kept as a protocol so `BackgroundSessionManager` does
/// not depend on the engine's concrete type — the delegate must be constructible at launch,
/// before the rest of the graph exists.
public protocol UploadEventSink: Sendable {
    func send(jobId: String, event: UploadEvent)
    func storeResumeData(jobId: String, data: Data)
    /// A `104` arrived: iOS and the server agreed on a draft revision and native resumption is
    /// live for this job. Its absence means the opposite, and matters — see
    /// docs/reference/wire-protocol.md.
    func noteNativeResumeSupported(jobId: String)
}

public struct UploadRequest: Sendable {
    public var sourceUri: String
    public var endpoint: String
    public var contentType: String
    public var metadata: [String: String] = [:]
    public var groupId: String?
    public var policy: UploadPolicy = .init()
    /// Override when the host app can do better than (uri, size, mtime) — e.g. an editable source.
    public var fingerprint: String?

    public init(sourceUri: String, endpoint: String, contentType: String) {
        self.sourceUri = sourceUri
        self.endpoint = endpoint
        self.contentType = contentType
    }
}
