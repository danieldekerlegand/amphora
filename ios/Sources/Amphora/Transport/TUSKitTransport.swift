import Foundation

/// Pre-iOS 17 fallback. The compromised one — read `docs/reference/ios-background-transfer.md` §4
/// before changing anything here.
///
/// **The problem.** A background `URLSession` upload task can only send a *whole file*
/// (`uploadTask(with:fromFile:)`; data bodies and streamed requests are unsupported). Below
/// iOS 17 the system has no notion of an upload offset, so to resume at byte N in the background
/// we must hand it a file that begins at byte N — i.e. materialise the remainder on disk.
///
/// That directly contradicts state-machine I6 ("no chunk temp file outlives a transport attempt"),
/// and I6 exists because staged files under storage pressure are exactly what corrupted uploads
/// in the previous implementation. So this transport does not get to ignore it. Instead:
///
///  - The remainder is staged **only when backgrounded transfer is actually required**. In the
///    foreground we stream ranges from the original file and stage nothing.
///  - Staging goes through `StorageGovernor` and holds a reservation for its whole lifetime. If
///    the reservation is refused, the job moves to `.blocked(.remainderStagingDenied)` — it waits
///    for space rather than corrupting.
///  - Staging lands in Application Support, never `Caches`/`tmp`. The "never purged while your
///    app is running" guarantee does not cover a *suspended* app, which is precisely our case.
///
/// **The honest summary:** below iOS 17 this costs up to 1× the remaining bytes in extra storage.
/// Setting the deployment target to iOS 17 removes this file and the entire failure mode with it.
public struct TUSKitTransport: UploadTransport {

    private let session: BackgroundSessionManager
    private let storage: StorageGovernor
    private let dialect: any WireDialect
    private let control: ControlPlaneClient

    public init(
        session: BackgroundSessionManager,
        storage: StorageGovernor,
        dialect: any WireDialect = Tus10Dialect(),
        control: ControlPlaneClient
    ) {
        self.session = session
        self.storage = storage
        self.dialect = dialect
        self.control = control
    }

    // TUSKit itself is not used for these: its value was tus 1.0 request construction, and
    // `Tus10Dialect` now covers that in ~40 lines without the dependency or its own scheduler
    // fighting our state machine.
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
        let sourceURL = URL(fileURLWithPath: job.stagedPath ?? job.sourceUri)

        // Offset zero needs no remainder — the original file *is* the body. Worth special-casing:
        // it is the common path for a first attempt, and it costs nothing.
        let bodyURL: URL
        let stagedRemainder: String?
        if offset == 0 {
            bodyURL = sourceURL
            stagedRemainder = nil
        } else {
            let needed = job.sizeBytes - offset
            guard let reservation = try await storage.reserveRemainder(jobId: job.id, bytes: needed) else {
                throw TransportError.remainderStagingDenied(needed: needed)
            }
            try await storage.writeRemainder(from: sourceURL, offset: offset, to: reservation.url)
            bodyURL = reservation.url
            stagedRemainder = reservation.url.path
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(dialect.appendContentType, forHTTPHeaderField: "Content-Type")
        dialect.decorate(&request)
        for (k, v) in dialect.appendHeaders(offset: offset, isFinalSlice: true) {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let taskId = session.startUpload(
            jobId: job.id, request: request, fileURL: bodyURL,
            expectedBytes: job.sizeBytes - offset
        )
        return TransferHandle(taskIdentifier: taskId, stagedRemainderPath: stagedRemainder)
    }

    public func terminate(uploadUrl: String) async throws {
        try await control.terminate(uploadUrl: uploadUrl)
    }
}
