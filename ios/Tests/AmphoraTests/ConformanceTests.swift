import Foundation
import Amphora

/// Why the vectors are not loaded by a relative path.
///
/// `Tests/Conformance/vectors.json` is the ONE file both ports read, and its whole job is to
/// stop the Swift and Kotlin state machines drifting apart. Reaching it as a repo-root-relative
/// path made the caller's working directory a hidden precondition of the suite: `swift run
/// AmphoraPathTests` from `ios/` died with NSCocoaErrorDomain 260, which reads as a broken
/// machine rather than as a red test. `#filePath` is baked in at compile time and is the one
/// anchor that does not move when the caller does, so the search walks up from this source file
/// until it finds the fixture. `ConformanceVectorsTest.kt` anchors the same way (via the
/// `amphora.repoRoot` system property Gradle injects), against the same single file.
enum ConformanceVectorsError: Error, LocalizedError, CustomStringConvertible {
    case notFound(searched: [String])
    case unreadable(path: String, underlying: Error)
    case malformed(path: String, detail: String)

    var description: String {
        switch self {
        case .notFound(let searched):
            return """
            conformance vectors not found. Looked for \(ConformanceVectors.relativePath) at each \
            ancestor of \(#filePath):
            \(searched.map { "  - \($0)" }.joined(separator: "\n"))
            """
        case .unreadable(let path, let underlying):
            return "conformance vectors at \(path) could not be read: \(underlying)"
        case .malformed(let path, let detail):
            return "conformance vectors at \(path) are malformed: \(detail)"
        }
    }

    var errorDescription: String? { description }
}

enum ConformanceVectors {
    static let relativePath = "Tests/Conformance/vectors.json"

    /// Locate the fixture by walking up from this source file. Independent of the process's
    /// working directory by construction.
    static func fileURL() throws -> URL {
        var searched: [String] = []
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            let candidate = directory.appendingPathComponent(relativePath)
            searched.append(candidate.path)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        throw ConformanceVectorsError.notFound(searched: searched)
    }

    /// Load and shape-check the fixture. Every failure here is a thrown, legible error rather
    /// than a trap: a missing or half-written fixture must fail the suite, and it must never be
    /// mistaken for "the vectors ran and agreed".
    static func load() throws -> (url: URL, schemaVersion: Int, vectors: [[String: Any]], root: [String: Any]) {
        let url = try fileURL()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConformanceVectorsError.unreadable(path: url.path, underlying: error)
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ConformanceVectorsError.malformed(path: url.path, detail: "\(error)")
        }
        guard let root = parsed as? [String: Any] else {
            throw ConformanceVectorsError.malformed(path: url.path, detail: "top level is not an object")
        }
        guard let schemaVersion = root["schemaVersion"] as? Int else {
            throw ConformanceVectorsError.malformed(path: url.path, detail: "missing integer `schemaVersion`")
        }
        guard let vectors = root["vectors"] as? [[String: Any]] else {
            throw ConformanceVectorsError.malformed(path: url.path, detail: "missing array `vectors`")
        }
        guard !vectors.isEmpty else {
            throw ConformanceVectorsError.malformed(path: url.path, detail: "`vectors` is empty — zero vectors is a failure, not a pass")
        }
        return (url, schemaVersion, vectors, root)
    }
}

extension UploadPathTests {
    /// The fixture's shape is asserted, never discovered.
    ///
    /// A test runner that discovers zero tests is a failure, not a pass, and the same holds for a
    /// vector suite: a truncated or half-written `vectors.json` must go red rather than quietly
    /// report a full run over a fraction of the rows. These numbers live in the test rather than
    /// in the fixture, so a fixture rewritten by a generator cannot rewrite its own expectations
    /// along with it. `ConformanceVectorsTest.kt` carries the identical three.
    static let expectedSchemaVersion = 2
    static let expectedVectorCount = 40

    /// `Enqueue` is the one event that creates a job rather than reducing one, so it has no
    /// `reduce` call to exercise and is counted instead of run. Asserting how many were skipped
    /// closes the hole a bare `continue` leaves: without it, a fixture whose rows had all
    /// degenerated to `Enqueue` would skip all forty, reduce nothing, and still pass.
    static let expectedUnreducedCount = 1

    /// Returns the number of vectors actually put through `reduce`, so the suite's summary line
    /// is a count of work done rather than a literal.
    @discardableResult
    static func conformanceVectors() throws -> Int {
        let (url, schemaVersion, vectors, _) = try ConformanceVectors.load()
        precondition(schemaVersion == expectedSchemaVersion, "expected vectors schemaVersion \(expectedSchemaVersion), got \(schemaVersion)")
        // Assert the count BEFORE reducing anything. A fixture truncated to eighteen rows should
        // fail as "expected 40 vectors, got 18", not as whichever unrelated assertion those
        // eighteen happen to trip over first.
        precondition(vectors.count == expectedVectorCount, "expected \(expectedVectorCount) vectors in \(url.path), got \(vectors.count)")

        var reduced = 0
        var unreduced = 0
        for vector in vectors {
            let id = vector["id"] as! String
            let given = vector["given"] as! [String: Any]
            let event = vector["event"] as! [String: Any]
            let expect = vector["expect"] as! [String: Any]
            if event["type"] as! String == "Enqueue" { unreduced += 1; continue }
            reduced += 1
            let transition = UploadStateMachine.reduce(makeJob(given), makeEvent(event), now: Date(timeIntervalSince1970: 10))
            let expected = UploadState(rawValue: (expect["state"] as! String).camelcased())!
            precondition(transition.job.state == expected, "\(id): expected \(expected), got \(transition.job.state)")
            if let value = expect["serverOffset"] as? Int { precondition(transition.job.serverOffset == value, "\(id): offset") }
            if let value = expect["bytesTransferred"] as? Int { precondition(transition.job.bytesTransferred == value, "\(id): bytes") }
            if let value = expect["attemptCount"] as? Int { precondition(transition.job.attemptCount == value, "\(id): attempts") }
            if expect["terminateRemote"] as? Bool == true { precondition(transition.effects.contains { if case .terminateRemote = $0 { return true }; return false }, "\(id): terminate") }
            if (expect["requiredEffects"] as? [String])?.contains("HEAD_BEFORE_RESUME") == true { precondition(transition.effects.contains(.headBeforeResume), "\(id): HEAD") }
        }

        precondition(unreduced == expectedUnreducedCount, "expected \(expectedUnreducedCount) non-reducing (Enqueue) vector, got \(unreduced) — a growing count means rows stopped being exercised")
        precondition(reduced == expectedVectorCount - expectedUnreducedCount, "expected \(expectedVectorCount - expectedUnreducedCount) vectors put through UploadStateMachine.reduce, got \(reduced) — 'ran 0 vectors' is a failure, not a pass")
            return reduced
    }

    private static func makeJob(_ given: [String: Any]) -> UploadJob {
        let now = Date(timeIntervalSince1970: 1)
        let state = UploadState(rawValue: (given["state"] as? String ?? "PENDING").camelcased())!
        return UploadJob(id: "vector", groupId: nil, sourceKind: .file, sourceUri: "vector", stagedPath: nil,
            sizeBytes: Int64(given["sizeBytes"] as? Int ?? 1000), contentType: "application/octet-stream", fingerprint: "vector", endpoint: "https://example.test",
            uploadUrl: given["uploadUrl"] as? String, uploadExpiresAt: nil, metadata: [:], state: state, pauseReason: nil,
            blockReason: (given["blockReason"] as? String).flatMap { BlockReason(rawValue: $0.camelcased()) }, errorClass: nil, errorDetail: nil,
            bytesTransferred: 0, serverOffset: Int64(given["serverOffset"] as? Int ?? 0), serverOffsetAt: nil,
            attemptCount: given["attemptCount"] as? Int ?? 0, nextAttemptAt: nil, reservedBytes: 0, ownerToken: nil, leaseExpiresAt: nil,
            taskIdentifier: nil, sessionIdentifier: nil, policy: UploadPolicy(), remoteTerminated: given["remoteTerminated"] as? Bool ?? true,
            createdAt: now, updatedAt: now, completedAt: nil, schemaVersion: UploadJob.schemaVersion)
    }

    private static func makeEvent(_ value: [String: Any]) -> UploadEvent {
        switch value["type"] as! String {
        case "Schedule": return .schedule
        case "SourceResolved": return .sourceResolved(sizeBytes: Int64(value["sizeBytes"] as! Int), fingerprint: value["fingerprint"] as! String, stagedPath: value["stagedPath"] as? String)
        case "SourceMissing": return .sourceMissing
        case "SpaceDenied": return .spaceDenied(needed: Int64(value["needed"] as! Int))
        case "RemoteCreated": return .remoteCreated(uploadUrl: value["uploadUrl"] as! String, expiresAt: nil)
        case "OffsetAdvanced": return .offsetAdvanced(serverOffset: Int64(value["serverOffset"] as! Int))
        case "TransportComplete": return .transportComplete
        case "ServerAck": return .serverAck
        case "TransportError": return .transportError(ErrorClass(rawValue: (value["errorClass"] as! String).camelcased())!, detail: value["detail"] as? String)
        case "Blocked": return .blocked(BlockReason(rawValue: (value["blockReason"] as! String).camelcased())!)
        case "Pause": return .pause
        case "Gone": return .gone
        case "OffsetDiverged": return .offsetDiverged(serverOffset: Int64(value["serverOffset"] as! Int))
        case "DeadlineReached": return .deadlineReached
        case "GateCleared": return .gateCleared
        case "Resume": return .resume
        case "Retry": return .retry
        case "Cancel": return .cancel
        case "ProcessStart": return .processStart
        case "AttemptsExhausted": return .attemptsExhausted
        default: fatalError("unknown vector event")
        }
    }
}

private extension String {
    func camelcased() -> String { split(separator: "_").enumerated().map { $0.offset == 0 ? $0.element.lowercased() : $0.element.capitalized }.joined() }
}

// MARK: - I6, the commitment that is not a state transition

extension UploadPathTests {
    /// I6 — "no chunk temp file outlives a transport attempt" — is the design claim with the
    /// largest consequence and the least protection. It is stated in `README.md`, in
    /// `state-machine.md` §4, and in both transports' doc comments; until these vectors it was
    /// checked nowhere. A port that stages "just the remainder" satisfies every transition vector
    /// in the fixture while taking peak extra storage from about zero to the size of the file, and
    /// reintroduces the class of bug — the OS reclaiming a cache file mid-transfer — that this
    /// design exists to retire.
    ///
    /// The rows are shared with Kotlin; the observation is necessarily port-specific. Here it is
    /// what `NativeResumableTransport` hands the background session: the original file, never a
    /// slice of it, with the remaining byte count as the expectation. `ConformanceVectorsTest.kt`
    /// makes the equivalent observation of `RangeRequestBody` streaming to its sink.
    static let expectedI6VectorCount = 3

    @discardableResult
    static func i6NoChunkTempFileVectors() async throws -> Int {
        let (url, _, _, root) = try ConformanceVectors.load()
        guard let section = root["transportInvariants"] as? [String: Any],
              let rows = section["i6NoChunkTempFiles"] as? [[String: Any]] else {
            throw ConformanceVectorsError.malformed(
                path: url.path,
                detail: "missing `transportInvariants.i6NoChunkTempFiles` — dropping that section would silently drop the only check on the no-chunk-temp-files commitment"
            )
        }
        // Asserted before any row runs, for the same reason the transition count is: a section
        // trimmed to one row must fail as "expected 3, got 1", not pass as a full I6 run.
        precondition(rows.count == expectedI6VectorCount, "expected \(expectedI6VectorCount) I6 vectors in \(url.path), got \(rows.count)")

        var checked = 0
        for row in rows {
            try await runI6Vector(
                id: row["id"] as! String,
                sizeBytes: Int64(row["sizeBytes"] as! Int),
                resumeFrom: Int64(row["resumeFrom"] as! Int),
                expect: row["expect"] as! [String: Any]
            )
            checked += 1
        }
        precondition(checked == expectedI6VectorCount, "ran \(checked) I6 vectors, expected \(expectedI6VectorCount) — 'ran 0 vectors' is a failure, not a pass")
            return checked
    }

    private static func runI6Vector(id: String, sizeBytes: Int64, resumeFrom: Int64, expect: [String: Any]) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("amphora-i6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source.bin")
        var bytes = Data(count: Int(sizeBytes))
        for index in 0..<Int(sizeBytes) { bytes[index] = UInt8(index % 251) }
        try bytes.write(to: source)

        // Point the process's temporary directory at the scratch directory for the duration of the
        // attempt. A remainder file is written either beside the source or "somewhere temporary";
        // this makes both land where the inventory below is looking.
        let previousTmp = ProcessInfo.processInfo.environment["TMPDIR"]
        setenv("TMPDIR", scratch.path, 1)
        defer {
            if let previousTmp { setenv("TMPDIR", previousTmp, 1) } else { unsetenv("TMPDIR") }
        }

        let before = try inventory(of: scratch)

        var job = makeJob([
            "state": "UPLOADING",
            "sizeBytes": Int(sizeBytes),
            "uploadUrl": "https://example.test/uploads/\(id)",
        ])
        job.sourceUri = source.path

        let recorder = RecordingBackgroundSession()
        let dialect = RufhDialect()
        let transport = NativeResumableTransport(
            session: recorder, dialect: dialect, control: ControlPlaneClient(dialect: dialect)
        )
        let handle = try await transport.startTransfer(job: job, from: resumeFrom)

        let created = try inventory(of: scratch).subtracting(before)
        let allowedFiles = expect["filesCreatedInWorkDir"] as! Int
        precondition(
            created.count == allowedFiles,
            "\(id): I6 violated — \(created.count) file(s) materialised during the attempt (\(created.sorted().joined(separator: ", "))), expected \(allowedFiles). Byte ranges stream from the source; nothing is written to disk."
        )

        if expect["stagesRemainder"] as? Bool == false {
            precondition(
                handle.stagedRemainderPath == nil,
                "\(id): I6 violated — the transport reported a staged remainder at \(handle.stagedRemainderPath ?? "")"
            )
        }

        let starts = recorder.started
        precondition(starts.count == 1, "\(id): expected exactly one upload task to be started, got \(starts.count)")
        let start = starts[0]
        precondition(
            start.fileURL.path == source.path,
            "\(id): the session was handed \(start.fileURL.path), not the original source \(source.path) — a slice of the file is a chunk temp file under another name"
        )
        let handedSize = (try FileManager.default.attributesOfItem(atPath: start.fileURL.path)[.size] as! NSNumber).int64Value
        precondition(
            handedSize == sizeBytes,
            "\(id): the file handed to the session is \(handedSize) bytes, the source is \(sizeBytes) — the transport must not rewrite or truncate it"
        )
        let expectedBytes = Int64(expect["bytesFromSource"] as! Int)
        precondition(
            start.expectedBytes == expectedBytes,
            "\(id): resuming from \(resumeFrom) should send \(expectedBytes) bytes, the session was told \(start.expectedBytes)"
        )
    }

    /// Every path under `directory`, relative to it. A set so the diff across an attempt names
    /// what appeared rather than merely counting it.
    private static func inventory(of directory: URL) throws -> Set<String> {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        // Resolve symlinks on the base: on macOS the temporary directory is /var/… while the
        // enumerator reports /private/var/…, and a prefix that never matches turns every relative
        // path in the failure message into nonsense.
        let base = directory.resolvingSymlinksInPath().path + "/"
        var paths: Set<String> = []
        for case let url as URL in walker {
            let resolved = url.resolvingSymlinksInPath().path
            paths.insert(resolved.hasPrefix(base) ? String(resolved.dropFirst(base.count)) : resolved)
        }
        return paths
    }
}

/// Stands in for `BackgroundSessionManager` so the I6 vectors can see what the transport hands
/// over without a real background `URLSession` — and without putting a task on the wire.
private final class RecordingBackgroundSession: BackgroundUploadStarting, @unchecked Sendable {
    struct Start {
        let jobId: String
        let fileURL: URL
        let expectedBytes: Int64
    }

    private(set) var started: [Start] = []

    func startUpload(jobId: String, request: URLRequest, fileURL: URL, expectedBytes: Int64) -> Int {
        started.append(Start(jobId: jobId, fileURL: fileURL, expectedBytes: expectedBytes))
        return started.count
    }
}
