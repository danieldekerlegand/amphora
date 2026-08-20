import Foundation
import Amphora

@main
struct AmphoraTusdIntegration {
    static func main() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["TUSD_ENDPOINT"] else {
            print("tusd integration: skipped (TUSD_ENDPOINT is not set)")
            return
        }

        let session = URLSession(configuration: .ephemeral)
        let dialect = Tus10Dialect()
        let control = ControlPlaneClient(session: session, dialect: dialect)
        let source = Data((0..<(3 * 1024 * 1024)).map { UInt8($0 % 251) })
        let created = try await control.create(
            endpoint: endpoint,
            sizeBytes: Int64(source.count),
            metadata: [:]
        )
        let initial = try await control.head(uploadUrl: created.uploadUrl)
        precondition(initial.offset == 0, "new tusd upload offset was \(initial.offset)")

        let firstCount = source.count * 2 / 5
        let first = try await patch(
            session: session, dialect: dialect, uploadUrl: created.uploadUrl,
            body: Data(source.prefix(firstCount)), offset: 0
        )
        precondition(first == firstCount, "first PATCH acknowledged offset \(first)")

        // Simulate process death: relaunching creates a new control client with no cached offset.
        let relaunched = ControlPlaneClient(session: session, dialect: dialect)
        let serverOffset = try await relaunched.head(uploadUrl: created.uploadUrl).offset
        precondition(serverOffset == firstCount, "relaunch HEAD returned \(serverOffset), expected \(firstCount)")
        let remainder = source.suffix(source.count - Int(serverOffset))
        let final = try await patch(
            session: session, dialect: dialect, uploadUrl: created.uploadUrl,
            body: remainder, offset: serverOffset
        )
        precondition(final == source.count, "resume PATCH acknowledged offset \(final)")

        // The server's response, not the locally sent byte count, is the completion proof.
        let completed = try await relaunched.head(uploadUrl: created.uploadUrl)
        precondition(completed.offset == source.count)

        var wrongVersion = URLRequest(url: URL(string: endpoint)!)
        wrongVersion.httpMethod = "POST"
        wrongVersion.httpBody = Data()
        wrongVersion.setValue("0", forHTTPHeaderField: "Content-Length")
        wrongVersion.setValue("9.9.9", forHTTPHeaderField: "Tus-Resumable")
        wrongVersion.setValue(String(source.count), forHTTPHeaderField: "Upload-Length")
        let (_, mismatchResponse) = try await session.data(for: wrongVersion)
        let mismatch = mismatchResponse as! HTTPURLResponse
        precondition((400...599).contains(mismatch.statusCode), "tusd accepted an unpinned version")

        try await control.terminate(uploadUrl: created.uploadUrl)
        var afterDelete = URLRequest(url: URL(string: created.uploadUrl)!)
        afterDelete.httpMethod = "HEAD"
        afterDelete.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        let (_, deletedResponse) = try await session.data(for: afterDelete)
        let deleted = deletedResponse as! HTTPURLResponse
        precondition(deleted.statusCode == 404 || deleted.statusCode == 410,
                     "terminated upload returned HTTP \(deleted.statusCode)")
        print("Swift tusd integration: 3 MiB process-death resume/patch/terminate passed")
    }

    private static func patch(
        session: URLSession, dialect: Tus10Dialect, uploadUrl: String,
        body: Data, offset: Int64
    ) async throws -> Int64 {
        var request = URLRequest(url: URL(string: uploadUrl)!)
        request.httpMethod = "PATCH"
        request.httpBody = body
        request.setValue(dialect.appendContentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        dialect.decorate(&request)
        let (_, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        precondition(http.statusCode == 204, "tusd PATCH returned HTTP \(http.statusCode)")
        return Int64(http.value(forHTTPHeaderField: "Upload-Offset")!)!
    }
}
