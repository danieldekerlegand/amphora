import Foundation

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

    private let session: BackgroundSessionManager
    private let dialect: any WireDialect
    private let control: ControlPlaneClient

    public init(
        session: BackgroundSessionManager,
        dialect: any WireDialect = RufhDialect(),
        control: ControlPlaneClient
    ) {
        self.session = session
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
    case badResponse
    case gone
    case http(Int)
    case remainderStagingDenied(needed: Int64)
}
