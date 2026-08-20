import Foundation

/// Throttles byte progress to ≤1 Hz per job (state machine I9).
///
/// `didSendBodyData` fires continuously for a multi-GB upload. Forwarding each callback to the
/// host — and across the React Native bridge in particular — saturates it and stalls the UI
/// thread, which presents to the user as the app freezing *because* the upload is working.
public final class ProgressCoalescer: @unchecked Sendable {

    private let interval: TimeInterval
    private let emit: @Sendable (String, Int64, Int64) -> Void
    private let lock = NSLock()
    private var lastEmitted: [String: Date] = [:]
    private var pending: [String: (sent: Int64, total: Int64)] = [:]

    public init(interval: TimeInterval = 1.0, emit: @escaping @Sendable (String, Int64, Int64) -> Void) {
        self.interval = interval
        self.emit = emit
    }

    public func record(jobId: String, bytesSent: Int64, total: Int64) {
        lock.lock()
        pending[jobId] = (bytesSent, total)
        let last = lastEmitted[jobId] ?? .distantPast
        let due = Date().timeIntervalSince(last) >= interval
        if due { lastEmitted[jobId] = Date() }
        lock.unlock()

        if due { emit(jobId, bytesSent, total) }
    }

    /// Always emit the final value, regardless of the throttle — a progress bar stuck at 97%
    /// because the last tick was swallowed is a bug report every single time.
    public func flush(jobId: String) {
        lock.lock()
        let value = pending.removeValue(forKey: jobId)
        lastEmitted.removeValue(forKey: jobId)
        lock.unlock()

        if let value { emit(jobId, value.sent, value.total) }
    }
}
