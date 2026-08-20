import Foundation

/// The seam between tus 1.0 and the IETF draft. See docs/reference/wire-protocol.md.
///
/// Kept as a dialect rather than conditionals inside the transport because the two protocols
/// differ in header names, content types *and* expiry semantics — scattering that produces a
/// transport where no single reading tells you which wire you are actually speaking.
public protocol WireDialect: Sendable {
    var appendContentType: String { get }
    func decorate(_ request: inout URLRequest)
    func creationHeaders(sizeBytes: Int64, metadata: [String: String]) -> [String: String]
    func appendHeaders(offset: Int64, isFinalSlice: Bool) -> [String: String]
    func readOffset(_ response: HTTPURLResponse) -> Int64?
    func readExpiry(_ response: HTTPURLResponse, now: Date) -> Date?
}

/// tus 1.0. The dialect tusd has spoken in production for a decade.
public struct Tus10Dialect: WireDialect {
    private let version = "1.0.0"
    public init() {}

    public var appendContentType: String { "application/offset+octet-stream" }

    public func decorate(_ request: inout URLRequest) {
        request.setValue(version, forHTTPHeaderField: "Tus-Resumable")
    }

    public func creationHeaders(sizeBytes: Int64, metadata: [String: String]) -> [String: String] {
        var headers = ["Upload-Length": String(sizeBytes)]
        if !metadata.isEmpty { headers["Upload-Metadata"] = Self.encodeMetadata(metadata) }
        return headers
    }

    public func appendHeaders(offset: Int64, isFinalSlice: Bool) -> [String: String] {
        ["Upload-Offset": String(offset)]
    }

    public func readOffset(_ response: HTTPURLResponse) -> Int64? {
        (response.value(forHTTPHeaderField: "Upload-Offset")).flatMap(Int64.init)
    }

    public func readExpiry(_ response: HTTPURLResponse, now: Date) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Upload-Expires") else { return nil }
        return Self.httpDateFormatter.date(from: raw)
    }

    /// `key <base64>, key2 <base64>` — space between key and value, comma between pairs.
    static func encodeMetadata(_ metadata: [String: String]) -> String {
        metadata.map { key, value in
            precondition(!key.contains(" ") && !key.contains(","), "invalid metadata key: \(key)")
            return "\(key) \(Data(value.utf8).base64EncodedString())"
        }
        .sorted()   // deterministic, so request signing and tests are reproducible
        .joined(separator: ",")
    }

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()
}

/// `draft-ietf-httpbis-resumable-upload`. What iOS 17+ speaks natively.
public struct RufhDialect: WireDialect {
    private let interopVersion: String
    public init(interopVersion: String = TusProtocol.interopVersion) {
        self.interopVersion = interopVersion
    }

    public var appendContentType: String { "application/partial-upload" }

    public func decorate(_ request: inout URLRequest) {
        request.setValue(interopVersion, forHTTPHeaderField: "Upload-Draft-Interop-Version")
    }

    public func creationHeaders(sizeBytes: Int64, metadata: [String: String]) -> [String: String] {
        // Structured-field booleans. ?1 means "this request carries the whole representation".
        ["Upload-Complete": "?1", "Upload-Length": String(sizeBytes)]
    }

    public func appendHeaders(offset: Int64, isFinalSlice: Bool) -> [String: String] {
        ["Upload-Offset": String(offset), "Upload-Complete": isFinalSlice ? "?1" : "?0"]
    }

    public func readOffset(_ response: HTTPURLResponse) -> Int64? {
        (response.value(forHTTPHeaderField: "Upload-Offset")).flatMap(Int64.init)
    }

    /// RUFH expresses lifetime as `Upload-Limit: max-age=<seconds>`, not an absolute date.
    public func readExpiry(_ response: HTTPURLResponse, now: Date) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Upload-Limit") else { return nil }
        for part in raw.split(separator: ",") {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.hasPrefix("max-age="), let seconds = TimeInterval(token.dropFirst(8)) {
                return now.addingTimeInterval(seconds)
            }
        }
        return nil
    }
}
