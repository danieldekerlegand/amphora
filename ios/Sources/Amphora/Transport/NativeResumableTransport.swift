import Foundation

/// The one call this transport makes into the session layer.
///
/// A protocol rather than the concrete `BackgroundSessionManager` so the I6 conformance vectors
/// (`Tests/Conformance/vectors.json` → `transportInvariants.i6NoChunkTempFiles`) can observe what
/// the transport hands over — which file, and how many bytes it expects to send — without standing
/// up a real background `URLSession` and putting a task on the wire. `BackgroundSessionManager` is
/// the only production conformer; the seam exists because "we hand over the original file, never a
/// slice of it" is a claim worth checking rather than asserting in a comment.
public protocol BackgroundUploadStarting: AnyObject {
    func startUpload(jobId: String, request: URLRequest, fileURL: URL, expectedBytes: Int64) -> Int
}

extension BackgroundSessionManager: BackgroundUploadStarting {}

/// A `Sendable` handle to whatever starts background uploads.
///
/// `UploadTransport` is `Sendable`, so a transport that stores a session reference directly stores
/// a non-`Sendable` class inside a `Sendable` struct — the complaint the `ios` CI job already
/// carries for `TUSKitTransport`, and one this seam would otherwise add a second instance of. The
/// wrapper is where the assertion is made instead of at the top of a whole class: the only thing
/// reachable through it is `startUpload`, which touches nothing but `URLSession`, and `URLSession`
/// is documented as safe to use from any thread. It is deliberately NOT the Sendable redesign
/// `BackgroundSessionManager` still needs — see docs/reference/continuous-integration.md,
/// "Known divergence".
public struct BackgroundUploadStarter: @unchecked Sendable {
    private let session: any BackgroundUploadStarting

    public init(_ session: any BackgroundUploadStarting) {
        self.session = session
    }

    func startUpload(jobId: String, request: URLRequest, fileURL: URL, expectedBytes: Int64) -> Int {
        session.startUpload(jobId: jobId, request: request, fileURL: fileURL, expectedBytes: expectedBytes)
    }
}

/// iOS 17+ path. The good one.
///
/// `URLSession` implements `draft-ietf-httpbis-resumable-upload` natively: it discovers server
/// support via `Upload-Complete`, handles the `104` handshake, and on a *background* session
/// resumes interrupted uploads automatically with no app code running. We hand it the original
/// file and the system does offset management internally.
///
/// The consequence that matters: **no chunk files, no remainder files, no staging.** Peak extra
/// storage is zero. This is the configuration that structurally cannot reproduce the
/// `TransferUtility` corruption bug, because there is nothing on disk for the OS to reclaim.
@available(iOS 17.0, *)
public struct NativeResumableTransport: UploadTransport {

    private let session: BackgroundUploadStarter
    private let dialect: any WireDialect
    private let control: ControlPlaneClient

    public init(
        session: any BackgroundUploadStarting,
        dialect: any WireDialect = RufhDialect(),
        control: ControlPlaneClient
    ) {
        self.session = BackgroundUploadStarter(session)
        self.dialect = dialect
        self.control = control
    }

    /// Runs on the foreground session: small request, and the reply is needed synchronously
    /// before we may start the background task (I2).
    public func create(endpoint: String, sizeBytes: Int64, metadata: [String: String]) async throws -> CreateResult {
        try await control.create(endpoint: endpoint, sizeBytes: sizeBytes, metadata: metadata)
    }

    public func head(uploadUrl: String) async throws -> HeadResult {
        try await control.head(uploadUrl: uploadUrl)
    }

    public func startTransfer(job: UploadJob, from offset: Int64) async throws -> TransferHandle {
        guard let url = job.uploadUrl.flatMap(URL.init(string:)) else {
            throw TransportError.missingUploadURL
        }
        // Always the *original* file. The system sends from `offset` itself once the server
        // confirms resumability, so we never slice the file ourselves.
        let fileURL = URL(fileURLWithPath: job.stagedPath ?? job.sourceUri)

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(dialect.appendContentType, forHTTPHeaderField: "Content-Type")
        dialect.decorate(&request)
        // The whole remainder goes in one task, so this slice is always the final one.
        for (k, v) in dialect.appendHeaders(offset: offset, isFinalSlice: true) {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let taskId = session.startUpload(
            jobId: job.id, request: request, fileURL: fileURL,
            expectedBytes: job.sizeBytes - offset
        )
        return TransferHandle(taskIdentifier: taskId, stagedRemainderPath: nil)
    }

    public func terminate(uploadUrl: String) async throws {
        try await control.terminate(uploadUrl: uploadUrl)
    }
}

public enum TransportError: Error, Equatable {
    case missingUploadURL
    case missingLocation
    case missingOffset
    case unexpectedOffset(actual: Int64)
    case badResponse
    case gone
    case http(Int)
    case remainderStagingDenied(needed: Int64)
}
