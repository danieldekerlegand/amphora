import Foundation

/// What a transfer strategy must provide. Two implementations exist because iOS 17 changed the
/// economics completely — see `NativeResumableTransport` and `TUSKitTransport`.
public protocol UploadTransport: Sendable {
    /// Creates the remote upload resource. The caller MUST persist the returned URL before any
    /// bytes are sent (state machine I2).
    func create(endpoint: String, sizeBytes: Int64, metadata: [String: String]) async throws -> CreateResult

    /// The authoritative offset. Called before every entry into `.uploading` (I1).
    func head(uploadUrl: String) async throws -> HeadResult

    /// Begin or continue the transfer. Returns once the transfer is *scheduled*, not finished;
    /// completion arrives through the session delegate.
    func startTransfer(job: UploadJob, from offset: Int64) async throws -> TransferHandle

    /// tus Termination extension. Always issuable, because the URL was persisted before the first
    /// byte — that is what makes an orphaned job cancelable.
    func terminate(uploadUrl: String) async throws
}

public struct CreateResult: Sendable {
    public let uploadUrl: String
    public let expiresAt: Date?

    public init(uploadUrl: String, expiresAt: Date?) {
        self.uploadUrl = uploadUrl
        self.expiresAt = expiresAt
    }
}

public struct HeadResult: Sendable {
    public let offset: Int64
    public let expiresAt: Date?

    public init(offset: Int64, expiresAt: Date?) {
        self.offset = offset
        self.expiresAt = expiresAt
    }
}

public struct TransferHandle: Sendable {
    public let taskIdentifier: Int?
    /// Set when the strategy had to materialise a remainder file. Tracked so the storage
    /// reservation can be released on every exit path (I5).
    public let stagedRemainderPath: String?

    public init(taskIdentifier: Int?, stagedRemainderPath: String?) {
        self.taskIdentifier = taskIdentifier
        self.stagedRemainderPath = stagedRemainderPath
    }
}

/// Chooses a strategy per device. Deliberately explicit rather than a silent fallback: the two
/// paths have materially different storage behaviour, and callers deserve to be able to log
/// which one they got when diagnosing a field report.
public enum TransportSelector {
    public static func select(
        session: BackgroundSessionManager,
        storage: StorageGovernor,
        tokenProvider: @escaping @Sendable () async -> String? = { nil }
    ) -> any UploadTransport {
        if #available(iOS 17.0, *) {
            let dialect = RufhDialect()
            return NativeResumableTransport(
                session: session, dialect: dialect,
                control: ControlPlaneClient(dialect: dialect, tokenProvider: tokenProvider)
            )
        }
        let dialect = Tus10Dialect()
        return TUSKitTransport(
            session: session, storage: storage, dialect: dialect,
            control: ControlPlaneClient(dialect: dialect, tokenProvider: tokenProvider)
        )
    }
}

public enum TusProtocol {
    /// Pin it. A server that outruns the deployed app population must fail loudly and
    /// distinguishably, not as a generic upload error. See platform-constraints.md §5.
    ///
    /// Note this is *our* pin. `URLSession`'s native path negotiates whatever revision Apple
    /// shipped, and a mismatch degrades silently to a non-resumable upload — see
    /// docs/reference/wire-protocol.md §"The iOS interop-version hazard".
    public static let interopVersion = "8"
}
