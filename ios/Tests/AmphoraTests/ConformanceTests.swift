import Foundation
import Amphora

extension UploadPathTests {
    static func conformanceVectors() throws {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "Tests/Conformance/vectors.json"))) as! [String: Any]
        let vectors = root["vectors"] as! [[String: Any]]
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
