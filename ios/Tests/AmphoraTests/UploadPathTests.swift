import Foundation
import Amphora

@main
struct UploadPathTests {
    static func main() async throws {
        try await plainFileUploadRunsCreateAppendCompleteInOrder()
        try await cancelDeletesStagedFile()
        print("Amphora path tests: 2 passed")
    }

    private static func plainFileUploadRunsCreateAppendCompleteInOrder() async throws {
        let source = try temporaryFile(contents: Data("amphora".utf8))
        let store = try temporaryStore()
        let transport = RecordingTransport()
        let engine = makeEngine(store: store, transport: transport)

        var request = UploadRequest(sourceUri: source.path, endpoint: "https://example.test/uploads", contentType: "text/plain")
        request.policy.allowsConstrainedNetwork = true
        let id = try await engine.enqueue(request)
        let calls = await transport.calls

        precondition(calls == ["create", "head", "append:0"], "wire calls were \(calls)")
        let uploading = try await store.get(id: id)
        precondition(uploading?.state == .uploading)

        await engine.dispatch(jobId: id, event: .transportComplete)
        await engine.dispatch(jobId: id, event: .serverAck)

        let completed = try await store.get(id: id)
        precondition(completed?.state == .completed)
        precondition(completed?.bytesTransferred == 7)
    }

    private static func cancelDeletesStagedFile() async throws {
        let source = try temporaryFile(contents: Data("source".utf8))
        let staged = try temporaryFile(contents: Data("staged".utf8))
        let store = try temporaryStore()
        let transport = RecordingTransport()
        let engine = makeEngine(store: store, transport: transport)

        let id = try await engine.enqueue(UploadRequest(sourceUri: source.path, endpoint: "https://example.test/uploads", contentType: "text/plain"))
        try await store.update(id: id) { job in
            job.stagedPath = staged.path
        }

        await engine.cancel(id: id)

        precondition(!FileManager.default.fileExists(atPath: staged.path))
        let canceled = try await store.get(id: id)
        precondition(canceled?.state == .canceled)
    }

    private static func makeEngine(store: any UploadStore, transport: RecordingTransport) -> DefaultUploadEngine {
        let storage = StorageGovernor()
        let network = NetworkGovernor(initialStatus: .unrestricted)
        let sources = SourceResolver(storage: storage)
        let session = BackgroundSessionManager(
            events: SilentSink(),
            progress: ProgressCoalescer { _, _, _ in }
        )
        return DefaultUploadEngine(
            store: store,
            sessionManager: session,
            transport: transport,
            storage: storage,
            network: network,
            sources: sources,
            emitter: NoopEventEmitter()
        )
    }

    private static func temporaryStore() throws -> SQLiteUploadStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("amphora-test-\(UUID().uuidString).sqlite")
        return try SQLiteUploadStore(url: url)
    }

    private static func temporaryFile(contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("amphora-test-\(UUID().uuidString).bin")
        try contents.write(to: url)
        return url
    }
}

private actor RecordingTransport: UploadTransport {
    private(set) var calls: [String] = []

    func create(endpoint: String, sizeBytes: Int64, metadata: [String: String]) async throws -> CreateResult {
        calls.append("create")
        return CreateResult(uploadUrl: "https://example.test/uploads/1", expiresAt: nil)
    }

    func head(uploadUrl: String) async throws -> HeadResult {
        calls.append("head")
        return HeadResult(offset: 0, expiresAt: nil)
    }

    func startTransfer(job: UploadJob, from offset: Int64) async throws -> TransferHandle {
        calls.append("append:\(offset)")
        return TransferHandle(taskIdentifier: 1, stagedRemainderPath: nil)
    }

    func terminate(uploadUrl: String) async throws {
        calls.append("terminate")
    }
}

private struct SilentSink: UploadEventSink {
    func send(jobId: String, event: UploadEvent) {}
    func storeResumeData(jobId: String, data: Data) {}
    func noteNativeResumeSupported(jobId: String) {}
}
