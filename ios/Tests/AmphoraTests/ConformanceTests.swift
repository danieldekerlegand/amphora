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
    static func load() throws -> (url: URL, schemaVersion: Int, vectors: [[String: Any]]) {
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
        return (url, schemaVersion, vectors)
    }
}

extension UploadPathTests {
    static func conformanceVectors() throws {
        let (_, schemaVersion, vectors) = try ConformanceVectors.load()
        precondition(schemaVersion == 1, "expected vectors schemaVersion 1, got \(schemaVersion)")
        for vector in vectors {
            let id = vector["id"] as! String
            let given = vector["given"] as! [String: Any]
            let event = vector["event"] as! [String: Any]
            let expect = vector["expect"] as! [String: Any]
            if event["type"] as! String == "Enqueue" { continue }
            let transition = UploadStateMachine.reduce(makeJob(given), makeEvent(event), now: Date(timeIntervalSince1970: 10))
            let expected = UploadState(rawValue: (expect["state"] as! String).camelcased())!
            precondition(transition.job.state == expected, "\(id): expected \(expected), got \(transition.job.state)")
            if let value = expect["serverOffset"] as? Int { precondition(transition.job.serverOffset == value, "\(id): offset") }
            if let value = expect["bytesTransferred"] as? Int { precondition(transition.job.bytesTransferred == value, "\(id): bytes") }
            if let value = expect["attemptCount"] as? Int { precondition(transition.job.attemptCount == value, "\(id): attempts") }
            if expect["terminateRemote"] as? Bool == true { precondition(transition.effects.contains { if case .terminateRemote = $0 { return true }; return false }, "\(id): terminate") }
            if (expect["requiredEffects"] as? [String])?.contains("HEAD_BEFORE_RESUME") == true { precondition(transition.effects.contains(.headBeforeResume), "\(id): HEAD") }
        }
        precondition(vectors.count == 40, "expected 40 vectors, got \(vectors.count)")
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
