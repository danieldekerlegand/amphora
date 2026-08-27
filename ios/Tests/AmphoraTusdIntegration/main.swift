import Foundation
import Amphora

// The Swift port's real-wire harness.
//
// It is PHASE-DRIVEN rather than one long function, and that shape is the whole point. The
// previous version simulated process death by allocating a second `ControlPlaneClient` inside the
// same process — a fresh object with no cached offset, but sharing the heap, the URLSession cache,
// the file descriptors and the address space of the first one. That demonstrates "this object does
// not remember the offset". It does not demonstrate "this *process* can die and the upload still
// finishes", which is the product thesis.
//
// So `send-prefix` ends by SIGKILLing itself. Not `exit(1)`, not a thrown error: SIGKILL, which
// runs no `defer`, flushes no buffer, closes no socket, and cannot be caught. The shell driver
// (integration/tusd/swift-wire.sh) observes exit status 137 and then invokes `resume` as a genuinely
// new process whose only inheritance is the upload URL on its command line. Everything else — the
// offset above all — has to come back off the wire via HEAD.
//
// Bodies are read through `Data(contentsOf:options:.mappedIfSafe)` and sliced. A memory-mapped
// slice is not a copy and is not a file: nothing is staged to disk, which is what invariant I6
// claims and what the driver measures while these phases run.

@main
struct AmphoraTusdIntegration {

    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "create":         try await create(endpoint: arg(args, 1), size: Int64(arg(args, 2))!)
        case "send-prefix":    try await sendPrefix(uploadUrl: arg(args, 1), path: arg(args, 2),
                                                   prefix: Int(arg(args, 3))!)
        case "resume":         try await resume(uploadUrl: arg(args, 1), path: arg(args, 2))
        case "reject-version": try await rejectVersion(endpoint: arg(args, 1))
        case "terminate":      try await terminate(uploadUrl: arg(args, 1))
        case nil:              try await singleProcess()
        case let other?:       fatal("unknown phase '\(other)'")
        }
    }

    // MARK: - phases

    /// Creates the upload resource and prints nothing but its URL, so the driver can capture it
    /// with a plain command substitution.
    private static func create(endpoint: String, size: Int64) async throws {
        let created = try await client().create(endpoint: endpoint, sizeBytes: size, metadata: [:])
        let initial = try await client().head(uploadUrl: created.uploadUrl)
        expect(initial.offset == 0, "a freshly created tusd upload reported offset \(initial.offset)")
        emit(created.uploadUrl)
    }

    /// Sends `[0, prefix)` and then dies without warning.
    ///
    /// `prefix` is chosen by the driver to exceed the S3 multipart minimum part size, so tusd has
    /// genuinely flushed a part to object storage before this process disappears — the resume then
    /// crosses a durability boundary rather than reading back a number tusd was still holding in
    /// memory.
    private static func sendPrefix(uploadUrl: String, path: String, prefix: Int) async throws {
        let source = try mapped(path)
        expect(prefix < source.count, "prefix \(prefix) is not shorter than the source")
        let acked = try await patch(uploadUrl: uploadUrl, body: source[0..<prefix], offset: 0)
        expect(acked == Int64(prefix), "prefix PATCH acknowledged offset \(acked), expected \(prefix)")
        emit("sent \(prefix) bytes, tusd acked offset \(acked); now killing pid \(getpid()) with SIGKILL")

        // Everything below this line must survive a process that never got to run it.
        fflush(stdout)
        kill(getpid(), SIGKILL)
        fatal("SIGKILL did not terminate this process")
    }

    /// A brand-new process. It is handed the upload URL and the source path and NOTHING else: no
    /// offset, no session, no open descriptor. The offset comes from the server or not at all.
    private static func resume(uploadUrl: String, path: String) async throws {
        let source = try mapped(path)
        let offset = try await client().head(uploadUrl: uploadUrl).offset
        expect(offset > 0, "the killed process left offset \(offset); nothing was resumed")
        expect(offset < Int64(source.count), "the killed process had already finished at \(offset)")

        let acked = try await patch(
            uploadUrl: uploadUrl, body: source[Int(offset)..<source.count], offset: offset
        )
        expect(acked == Int64(source.count), "resume PATCH acknowledged offset \(acked)")

        // The server's own answer, not the byte count this process sent, is the completion proof.
        let completed = try await client().head(uploadUrl: uploadUrl).offset
        expect(completed == Int64(source.count), "post-resume HEAD reported offset \(completed)")
        emit("resumed from server offset \(offset) and completed at \(completed) of \(source.count)")
    }

    /// Fail-closed interop pin: a request advertising a different tus version must not create an
    /// upload. Catches accidental negotiation, or a proxy stripping the protocol header.
    private static func rejectVersion(endpoint: String) async throws {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.httpBody = Data()
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        request.setValue("9.9.9", forHTTPHeaderField: "Tus-Resumable")
        request.setValue("1", forHTTPHeaderField: "Upload-Length")
        let status = try await status(of: request)
        expect((400...599).contains(status), "tusd accepted an unpinned Tus-Resumable (HTTP \(status))")
        emit("unpinned Tus-Resumable rejected with HTTP \(status)")
    }

    private static func terminate(uploadUrl: String) async throws {
        try await client().terminate(uploadUrl: uploadUrl)
        var request = URLRequest(url: URL(string: uploadUrl)!)
        request.httpMethod = "HEAD"
        request.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        let status = try await status(of: request)
        expect(status == 404 || status == 410, "terminated upload still answers HTTP \(status)")
        emit("terminated; HEAD now returns HTTP \(status)")
    }

    /// The original single-process flow, kept because the guide documents it and because it is a
    /// useful smoke test when no shell driver is around. It is NOT evidence of process-death
    /// resume — the phases above are. Anything that needs that claim must run the driver.
    private static func singleProcess() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["TUSD_ENDPOINT"] else {
            emit("tusd integration: skipped (TUSD_ENDPOINT is not set)")
            return
        }
        let source = Data((0..<(3 * 1024 * 1024)).map { UInt8($0 % 251) })
        let control = client()
        let created = try await control.create(
            endpoint: endpoint, sizeBytes: Int64(source.count), metadata: [:]
        )
        expect(try await control.head(uploadUrl: created.uploadUrl).offset == 0, "new upload is not at 0")

        let firstCount = source.count * 2 / 5
        let first = try await patch(uploadUrl: created.uploadUrl, body: source[0..<firstCount], offset: 0)
        expect(first == Int64(firstCount), "first PATCH acknowledged offset \(first)")

        let serverOffset = try await client().head(uploadUrl: created.uploadUrl).offset
        expect(serverOffset == Int64(firstCount), "second HEAD returned \(serverOffset)")
        let final = try await patch(
            uploadUrl: created.uploadUrl,
            body: source[Int(serverOffset)..<source.count], offset: serverOffset
        )
        expect(final == Int64(source.count), "resume PATCH acknowledged offset \(final)")
        expect(try await client().head(uploadUrl: created.uploadUrl).offset == Int64(source.count),
               "post-resume HEAD disagreed with the bytes sent")

        try await rejectVersion(endpoint: endpoint)
        try await terminate(uploadUrl: created.uploadUrl)
        emit("Swift tusd integration (single process): 3 MiB patch/resume/terminate passed")
    }

    // MARK: - plumbing

    private static let dialect = Tus10Dialect()

    /// A new URLSession every time, deliberately: within one process the phases must not share
    /// connection state either.
    private static func client() -> ControlPlaneClient {
        ControlPlaneClient(session: URLSession(configuration: .ephemeral), dialect: dialect)
    }

    /// Memory-mapped, never copied to a scratch file. `.mappedIfSafe` is what makes the driver's
    /// peak-extra-disk measurement meaningful: a transport that staged its remainder would show up
    /// as megabytes appearing under the scratch directory, and this one has nothing to show.
    private static func mapped(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    }

    private static func patch(uploadUrl: String, body: Data, offset: Int64) async throws -> Int64 {
        var request = URLRequest(url: URL(string: uploadUrl)!)
        request.httpMethod = "PATCH"
        request.httpBody = body
        request.setValue(dialect.appendContentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        dialect.decorate(&request)
        let session = URLSession(configuration: .ephemeral)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { fatal("PATCH got a non-HTTP response") }
        expect(http.statusCode == 204, "tusd PATCH returned HTTP \(http.statusCode)")
        guard let header = http.value(forHTTPHeaderField: "Upload-Offset"), let acked = Int64(header)
        else { fatal("tusd PATCH carried no usable Upload-Offset") }
        return acked
    }

    private static func status(of request: URLRequest) async throws -> Int {
        let session = URLSession(configuration: .ephemeral)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { fatal("expected an HTTP response") }
        return http.statusCode
    }

    private static func arg(_ args: [String], _ index: Int) -> String {
        guard index < args.count else { fatal("phase '\(args[0])' is missing argument \(index)") }
        return args[index]
    }

    private static func emit(_ message: String) {
        print(message)
        fflush(stdout)
    }

    /// A failed expectation exits 1 — "ran and failed" — rather than trapping. `precondition`
    /// aborts with SIGILL, and a signal death is exactly what `send-prefix` uses to mean something
    /// else entirely; the driver must be able to tell the two apart.
    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { fatal(message()) }
    }

    private static func fatal(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}
