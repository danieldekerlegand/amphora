import Foundation

/// The small, synchronous half of the protocol: create, offset query, terminate.
///
/// Runs on an ordinary foreground `URLSession`, not the background one. Background sessions are
/// for bulk transfer — they may defer a request for hours under `isDiscretionary`, and a `HEAD`
/// we are blocked on must not be subject to that. Only the PATCH body goes to the background
/// session.
public struct ControlPlaneClient: Sendable {

    private let session: URLSession
    private let dialect: any WireDialect
    private let tokenProvider: @Sendable () async -> String?
    private let now: @Sendable () -> Date

    public init(
        session: URLSession = .shared,
        dialect: any WireDialect,
        tokenProvider: @escaping @Sendable () async -> String? = { nil },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.dialect = dialect
        self.tokenProvider = tokenProvider
        self.now = now
    }

    public func create(
        endpoint: String, sizeBytes: Int64, metadata: [String: String]
    ) async throws -> CreateResult {
        guard let url = URL(string: endpoint) else { throw TransportError.missingUploadURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        dialect.decorate(&request)
        for (k, v) in dialect.creationHeaders(sizeBytes: sizeBytes, metadata: metadata) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        await authorize(&request)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TransportError.badResponse }
        // tus answers 201; RUFH answers 104 and URLSession surfaces the final status. Accept any
        // 2xx carrying a Location rather than pinning an exact code.
        guard (200...204).contains(http.statusCode) || http.statusCode == 104 else {
            throw TransportError.http(http.statusCode)
        }
        guard let location = http.value(forHTTPHeaderField: "Location") else {
            throw TransportError.missingLocation
        }

        // Location MAY be relative, and tusd behind a reverse proxy commonly returns one. Storing
        // it unresolved yields a job that can never be resumed *or* terminated after restart,
        // since nothing else on the device records the base URL.
        guard let resolved = URL(string: location, relativeTo: url)?.absoluteURL else {
            throw TransportError.missingLocation
        }

        return CreateResult(
            uploadUrl: resolved.absoluteString,
            expiresAt: dialect.readExpiry(http, now: now())
        )
    }

    /// Authoritative offset. Called before every entry into `.uploading` (I1).
    public func head(uploadUrl: String) async throws -> HeadResult {
        guard let url = URL(string: uploadUrl) else { throw TransportError.missingUploadURL }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        // An intermediary caching this response is catastrophic: we would resume from a stale
        // offset and every subsequent PATCH would 409.
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        dialect.decorate(&request)
        await authorize(&request)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TransportError.badResponse }

        switch http.statusCode {
        case 404, 410:
            throw TransportError.gone
        case 200...204:
            guard let offset = dialect.readOffset(http) else { throw TransportError.missingOffset }
            guard offset >= 0 else { throw TransportError.unexpectedOffset(actual: offset) }
            return HeadResult(offset: offset, expiresAt: dialect.readExpiry(http, now: now()))
        default:
            throw TransportError.http(http.statusCode)
        }
    }

    public func terminate(uploadUrl: String) async throws {
        guard let url = URL(string: uploadUrl) else { throw TransportError.missingUploadURL }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        dialect.decorate(&request)
        await authorize(&request)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TransportError.badResponse }
        // Already gone is success, not failure — the resource is reclaimed either way.
        guard (200...204).contains(http.statusCode) || http.statusCode == 404 || http.statusCode == 410
        else { throw TransportError.http(http.statusCode) }
    }

    private func authorize(_ request: inout URLRequest) async {
        if let token = await tokenProvider() {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
    }
}

public extension TransportError {
    /// Maps transport failures onto the retry policy the state machine reasons about.
    var errorClass: ErrorClass {
        switch self {
        case .gone: return .fatal          // caller converts to `.gone` before reaching here
        case .missingUploadURL, .missingLocation, .missingOffset, .unexpectedOffset, .badResponse: return .protocolError
        case .remainderStagingDenied: return .local
        case let .http(code):
            switch code {
            case 401, 403: return .auth
            case 409, 460: return .protocolError
            case 412: return .protocolVersion
            case 400, 413: return .fatal
            case 429, 500...599: return .transient
            default: return .fatal
            }
        }
    }
}
