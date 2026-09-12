import Foundation
import Amphora

@main
struct UploadPathTests {
    /// The upload-path cases below, counted so the summary line is derived rather than typed.
    static let pathCases = 5

    static func main() async throws {
        // The shared fixture runs FIRST, and deliberately. Every `precondition` here traps the
        // process, so whichever check fails first is the only one a reader ever sees — and when a
        // port drifts, the message worth seeing is the shared row's id, not a port-local case that
        // happens to trip over the same defect one line earlier. A fixture the runner cannot find
        // must fail this suite loudly rather than trap or, worse, be skipped into a green run.
        let vectors: Int
        let i6Vectors: Int
        let stagingVectors: Int
        do {
            vectors = try conformanceVectors()
            i6Vectors = try await i6NoChunkTempFileVectors()
            stagingVectors = try await sourceStagingVectors()
        } catch {
            FileHandle.standardError.write(Data("Amphora path tests: FAILED — \(error)\n".utf8))
            exit(1)
        }

        try await plainFileUploadRunsCreateAppendCompleteInOrder()
        try await photosAssetIsStagedBeforeTheRemoteIsCreated()
        try await cancelDeletesStagedFile()
        try await remainderStreamsFromOffset()
        try await remainderAbortsAndCleansUpWhenPressureRises()
        // Counted, not asserted from memory. A summary line whose number is a literal cannot tell
        // "the vectors ran" from "the vectors were skipped", which is the failure mode this whole
        // fixture exists to rule out.
        print("Amphora path tests: \(pathCases + vectors + i6Vectors + stagingVectors) passed "
            + "(\(pathCases) upload-path cases, \(vectors) state-machine vectors, "
            + "\(i6Vectors) I6 transport vectors, \(stagingVectors) source-staging vectors)")
    }

    private static func plainFileUploadRunsCreateAppendCompleteInOrder() async throws {
        let source = try temporaryFile(contents: Data("amphora".utf8))
        let store = try temporaryStore()
        let transport = RecordingTransport()
        let engine = makeEngine(store: store, transport: transport)

        var request = UploadRequest(sourceUri: source.path, endpoint: "https://example.test/uploads", contentType: "text/plain")
        request.policy.allowsConstrainedNetwork = true
        let id = try await engine.enqueue(request)
        let calls = await transport.log.calls

        precondition(calls == ["create", "head", "append:0"], "wire calls were \(calls)")
        let uploading = try await store.get(id: id)
        precondition(uploading?.state == .uploading)

        await engine.dispatch(jobId: id, event: .transportComplete)
        await engine.dispatch(jobId: id, event: .serverAck)

        let completed = try await store.get(id: id)
        precondition(completed?.state == .completed)
        precondition(completed?.bytesTransferred == 7)
    }

    /// The `ph://` path, end to end through the engine — the one source this library is *required*
    /// to copy (CLAUDE.md §2), and the one that had no caller until now.
    ///
    /// Two properties, one case. First that the copy happens **before** the remote exists: a
    /// reservation refused after `create` would have already orphaned a server resource. Second
    /// that a refusal blocks instead of proceeding, leaving nothing behind.
    private static func photosAssetIsStagedBeforeTheRemoteIsCreated() async throws {
        let assetBytes = Data("a photos asset, exported".utf8)

        // -- staged ---------------------------------------------------------
        let log = CallLog()
        let photos = FakePhotosAssetSource(log: log, bytes: assetBytes)
        let storage = StorageGovernor(capacityProvider: { .max }, photos: photos)
        let store = try temporaryStore()
        let transport = RecordingTransport(log: log)
        let engine = makeEngine(store: store, transport: transport, storage: storage, photos: photos)

        var request = UploadRequest(sourceUri: "ph://asset-1", endpoint: "https://example.test/uploads", contentType: "image/jpeg")
        request.policy.allowsConstrainedNetwork = true
        let id = try await engine.enqueue(request)

        let calls = await log.calls
        precondition(calls == ["export", "create", "head", "append:0"], "wire calls were \(calls)")

        let job = try await store.get(id: id)
        guard let staged = job?.stagedPath else { preconditionFailure("ph:// job was not staged") }
        let stagingDirectory = try await storage.stagingDirectory().path
        precondition(staged.hasPrefix(stagingDirectory + "/"), "staged outside the reservation directory: \(staged)")
        let stagedBytes = try Data(contentsOf: URL(fileURLWithPath: staged))
        precondition(stagedBytes == assetBytes, "staged bytes differ from the asset")
        precondition(job?.sourceKind == .stagedCopy, "sourceKind was \(String(describing: job?.sourceKind))")

        let handed = await transport.transferredJob
        precondition(handed?.id == id, "transport was handed \(String(describing: handed?.id))")
        precondition(handed?.stagedPath == staged, "transport was handed an unstaged job")

        // The reservation is real and lands in the app's Application Support directory, so this
        // case cleans up after itself rather than leaving a .part behind on a developer machine.
        await storage.release(jobId: id)

        // -- refused --------------------------------------------------------
        let refusedLog = CallLog()
        let refusedPhotos = FakePhotosAssetSource(log: refusedLog, bytes: assetBytes)
        let refusedStorage = StorageGovernor(capacityProvider: { 0 }, photos: refusedPhotos)
        let refusedStore = try temporaryStore()
        let refusedTransport = RecordingTransport(log: refusedLog)
        let refusedEngine = makeEngine(
            store: refusedStore, transport: refusedTransport, storage: refusedStorage, photos: refusedPhotos
        )

        var refusedRequest = UploadRequest(sourceUri: "ph://asset-2", endpoint: "https://example.test/uploads", contentType: "image/jpeg")
        refusedRequest.policy.allowsConstrainedNetwork = true
        let refusedId = try await refusedEngine.enqueue(refusedRequest)

        let refusedCalls = await refusedLog.calls
        precondition(refusedCalls.isEmpty, "a refused reservation still reached the wire: \(refusedCalls)")
        let blocked = try await refusedStore.get(id: refusedId)
        precondition(blocked?.state == .blocked, "state was \(String(describing: blocked?.state))")
        precondition(blocked?.blockReason == .storageLow, "blockReason was \(String(describing: blocked?.blockReason))")
        let orphan = try await refusedStorage.stagingDirectory().appendingPathComponent("\(refusedId).part")
        precondition(!FileManager.default.fileExists(atPath: orphan.path), "a .part file survived a refusal")
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

    private static func remainderStreamsFromOffset() async throws {
        let source = try temporaryFile(contents: Data("0123456789".utf8))
        let destination = temporaryURL()
        let storage = StorageGovernor(capacityProvider: { Int64.max })

        try await storage.writeRemainder(from: source, offset: 4, to: destination)
        let remainder = try Data(contentsOf: destination)
        precondition(remainder == Data("456789".utf8))
    }

    private static func remainderAbortsAndCleansUpWhenPressureRises() async throws {
        let source = try temporaryFile(contents: Data(repeating: 7, count: 2 * 1024 * 1024))
        let destination = temporaryURL()
        let capacity = CapacityProbe(values: [Int64.max, Int64.max, 0])
        let storage = StorageGovernor(capacityProvider: { capacity.next() })

        do {
            try await storage.writeRemainder(from: source, offset: 0, to: destination)
            preconditionFailure("remainder write should abort when pressure rises")
        } catch StorageError.pressureRose {
            precondition(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    /// `capacityProvider: { .max }` by default: a test machine's real free space is not an input
    /// any of these cases means to depend on, and the two that do care pass their own governor.
    static func makeEngine(
        store: any UploadStore,
        transport: RecordingTransport,
        storage: StorageGovernor = StorageGovernor(capacityProvider: { .max }),
        photos: any PhotosAssetSource = SystemPhotosAssetSource()
    ) -> DefaultUploadEngine {
        let network = NetworkGovernor(initialStatus: .unrestricted)
        let sources = SourceResolver(storage: storage, photos: photos)
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

    static func temporaryStore() throws -> SQLiteUploadStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("amphora-test-\(UUID().uuidString).sqlite")
        return try SQLiteUploadStore(url: url)
    }

    static func temporaryFile(contents: Data) throws -> URL {
        let url = temporaryURL()
        try contents.write(to: url)
        return url
    }

    static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("amphora-test-\(UUID().uuidString).bin")
    }
}

private final class CapacityProbe: @unchecked Sendable {
    private var values: [Int64]

    init(values: [Int64]) {
        self.values = values
    }

    func next() -> Int64 {
        values.isEmpty ? 0 : values.removeFirst()
    }
}

/// One log, shared by the transport and the Photos double. Ordering *between* the two is the
/// property under test — an export recorded in its own list could not be placed before `create`.
actor CallLog {
    private(set) var calls: [String] = []

    func record(_ call: String) {
        calls.append(call)
    }
}

actor RecordingTransport: UploadTransport {
    let log: CallLog
    private(set) var transferredJob: UploadJob?

    init(log: CallLog = CallLog()) {
        self.log = log
    }

    func create(endpoint: String, sizeBytes: Int64, metadata: [String: String]) async throws -> CreateResult {
        await log.record("create")
        return CreateResult(uploadUrl: "https://example.test/uploads/1", expiresAt: nil)
    }

    func head(uploadUrl: String) async throws -> HeadResult {
        await log.record("head")
        return HeadResult(offset: 0, expiresAt: nil)
    }

    func startTransfer(job: UploadJob, from offset: Int64) async throws -> TransferHandle {
        await log.record("append:\(offset)")
        transferredJob = job
        return TransferHandle(taskIdentifier: 1, stagedRemainderPath: nil)
    }

    func terminate(uploadUrl: String) async throws {
        await log.record("terminate")
    }
}

/// Known bytes and a fixed modification date, so the fingerprint `probe` computes at enqueue is the
/// one `isIntact` recomputes at transfer. Records only `export`: `metadata` is synchronous and is
/// read on both paths, so logging it would say nothing about ordering.
struct FakePhotosAssetSource: PhotosAssetSource {
    let log: CallLog
    let bytes: Data

    func metadata(forLocalIdentifier localIdentifier: String) throws -> PhotosAssetMetadata {
        PhotosAssetMetadata(estimatedSizeBytes: Int64(bytes.count), modificationDate: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func export(localIdentifier: String, to destination: URL) async throws {
        await log.record("export")
        try bytes.write(to: destination)
    }
}

private struct SilentSink: UploadEventSink {
    func send(jobId: String, event: UploadEvent) {}
    func storeResumeData(jobId: String, data: Data) {}
    func noteNativeResumeSupported(jobId: String) {}
}
