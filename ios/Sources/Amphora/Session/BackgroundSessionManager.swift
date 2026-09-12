import Foundation
import os

/// Owns the one background `URLSession` for the whole process.
///
/// Three rules from Apple's guidance, all of them load-bearing:
///
///  1. **Exactly one background session, with a stable identifier.** Two sessions with the same
///     identifier is a runtime error; a changing identifier orphans every in-flight task.
///  2. **Recreate it early in launch, before events arrive.** The system may relaunch the app
///     specifically to deliver completion, and the delegate must exist when it does.
///  3. **Delegate only — no completion handlers.** The app can be terminated and relaunched
///     between starting a task and its completion, so a closure has nowhere to live.
///
/// Task objects do *not* survive relaunch — the session recreates them. What survives is
/// `taskIdentifier`, `originalRequest.url`, and `taskDescription`. We stamp `taskDescription`
/// with the job id and persist `taskIdentifier`, then match on either. That pair is the entire
/// basis of the adopt path in `Reconciler`.
///
/// # Concurrency model
///
/// This type is reached from at least four directions at once, which is why the model is written
/// down rather than inferred: the session's own **delegate queue** (`delegateQueue: nil` means a
/// private serial `OperationQueue`, so delegate callbacks are serial with respect to each other
/// but on no queue we control), **`DispatchQueue.main`** in `urlSessionDidFinishEvents`, the
/// **app delegate's** call to `setSystemCompletionHandler` during launch, and **arbitrary async
/// callers** of `startUpload` / `pause` / `cancel` / `liveTasks` from whatever executor the engine
/// happens to be on.
///
/// Every stored property, and how it is safe:
///
/// | Property | Mutable | Touched from | Protection |
/// |---|---|---|---|
/// | `log` | no | everywhere | `Logger` is a value type and documented thread-safe |
/// | `events` | no | delegate queue | `UploadEventSink` refines `Sendable` |
/// | `progress` | no | delegate queue | `ProgressCoalescer` guards its own state with `NSLock` |
/// | `lock` | no | everywhere | it *is* the protection |
/// | `storedSession` | yes — written once in `init` | every method, via `session` | `lock` |
/// | `storedCompletion` | yes | app delegate + delegate queue | `lock` |
///
/// `NSLock`, not `OSAllocatedUnfairLock` or `Mutex`: those are iOS 16+ / iOS 18+, and the package
/// minimum is iOS 15 (`ios/Package.swift`). Not an actor either — `URLSessionDelegate` callbacks
/// are synchronous and non-isolated, so an actor would only move the problem into a `Task` and
/// lose the ordering the delegate queue already gives us.
///
/// The conformance is therefore `@unchecked Sendable` and the table above is what it is checked
/// against by a reader. Declaring plain `Sendable` is impossible (the superclass `NSObject` is not
/// `Sendable`), and declaring *either* over an unguarded `var` — which is what this type carried
/// until tasklist `140` — is the defect restated rather than fixed.
public final class BackgroundSessionManager: NSObject, @unchecked Sendable {

    public static let sessionIdentifier = "dev.amphora.upload.background.v1"

    private let log = Logger(subsystem: "dev.amphora", category: "session")
    private let events: any UploadEventSink
    private let progress: ProgressCoalescer

    /// Guards `storedSession` and `storedCompletion`, and nothing else. Held for single field
    /// reads and writes only: no network call, no delegate dispatch and no `await` happens under
    /// it, so it cannot be the thing that deadlocks a relaunch.
    private let lock = NSLock()

    /// The session. Optional and `var` for exactly one reason: `URLSession` needs `self` as its
    /// delegate, and `self` does not exist until after `super.init()` — which Swift will not let a
    /// `let` be assigned past. It is written once, in `init`, and read through `session` after.
    private var storedSession: URLSession?

    /// Set by the app delegate's `handleEventsForBackgroundURLSession`. Must be invoked on the
    /// main thread once `urlSessionDidFinishEvents` fires, or the system stops relaunching us.
    private var storedCompletion: SystemCompletion?

    /// UIKit hands the app delegate a bare `() -> Void`, and we do not get to change that
    /// signature. Boxing it is what lets the handler be carried from the delegate queue to
    /// `DispatchQueue.main` without demanding a `@Sendable` closure the host cannot produce.
    /// Safe because the box is *handed off*, never shared: `urlSessionDidFinishEvents` takes it
    /// out from under `lock` and nils the field in the same critical section, so the closure has
    /// exactly one owner and is called exactly once.
    private struct SystemCompletion: @unchecked Sendable {
        let call: () -> Void
    }

    /// Never `nil` in practice — `init` assigns it before returning, and nothing clears it.
    private var session: URLSession {
        lock.lock()
        defer { lock.unlock() }
        guard let storedSession else {
            preconditionFailure("BackgroundSessionManager.session read before init finished")
        }
        return storedSession
    }

    public init(events: any UploadEventSink, progress: ProgressCoalescer) {
        self.events = events
        self.progress = progress
        super.init()

        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)

        // Let the system pick a good moment for large transfers. Forced off in debug, or uploads
        // may be deferred for hours and nothing is testable.
        #if DEBUG
        config.isDiscretionary = false
        #else
        config.isDiscretionary = true
        #endif

        // Respect Low Data Mode. `waitsForConnectivity` is deliberately not set: background
        // sessions always wait for connectivity, so setting it has no effect.
        config.allowsConstrainedNetworkAccess = false
        config.allowsExpensiveNetworkAccess = true
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60   // a week; large uploads are slow

        // Eagerly, not lazily: rule 2 above. The system may have relaunched us *in order to*
        // deliver events, and the delegate has to exist before the first one arrives.
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        lock.lock()
        storedSession = session
        lock.unlock()
    }

    // MARK: - Discovery

    /// Everything the system is still holding for us. The other half of the reconciler's join.
    public func liveTasks() async -> [LiveTask] {
        let tasks = await session.allTasks
        return tasks.compactMap { task in
            guard let jobId = task.taskDescription else {
                // A task we cannot attribute is worse than useless: it will keep writing to an
                // upload URL we no longer track. Cancel it and let recovery restart cleanly.
                self.log.error("orphan task \(task.taskIdentifier) with no description; canceling")
                task.cancel()
                return nil
            }
            return LiveTask(jobId: jobId, taskIdentifier: task.taskIdentifier, state: task.state)
        }
    }

    // MARK: - Transfer control

    public func startUpload(jobId: String, request: URLRequest, fileURL: URL, expectedBytes: Int64) -> Int {
        // Background sessions accept `fromFile:` only. Data bodies and streamed requests are
        // unsupported, which is why the transport streams from a file rather than a byte buffer.
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = jobId
        task.countOfBytesClientExpectsToSend = expectedBytes   // helps the scheduler size the work
        task.resume()
        return task.taskIdentifier
    }

    /// Pause. On iOS 17+ this yields resume data implementing the IETF draft; the returned blob is
    /// persisted so the upload can continue from its offset rather than from zero.
    public func pause(jobId: String) async -> Data? {
        guard let task = await task(for: jobId) as? URLSessionUploadTask else { return nil }
        if #available(iOS 17.0, *) {
            return await task.cancelByProducingResumeData()
        }
        task.cancel()
        return nil
    }

    public func cancel(jobId: String) async {
        await task(for: jobId)?.cancel()
    }

    private func task(for jobId: String) async -> URLSessionTask? {
        await session.allTasks.first { $0.taskDescription == jobId }
    }

    public func setSystemCompletionHandler(_ handler: @escaping () -> Void) {
        let boxed = SystemCompletion(call: handler)
        lock.lock()
        storedCompletion = boxed
        lock.unlock()
    }

    public struct LiveTask: Sendable {
        public let jobId: String
        public let taskIdentifier: Int
        public let state: URLSessionTask.State
    }
}

// MARK: - URLSessionDelegate

extension BackgroundSessionManager: URLSessionDataDelegate {

    /// The system has finished replaying every queued event into a relaunched app. Calling the
    /// stored handler is not optional — skip it and iOS deprioritises, then stops, relaunching us.
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Take it and clear it in one critical section, then hop. The old code did both *inside*
        // the main-queue block, so two events replayed close together could each see the handler
        // still set and call it twice — and it also mutated the field from a second thread.
        lock.lock()
        let completion = storedCompletion
        storedCompletion = nil
        lock.unlock()

        guard let completion else { return }
        DispatchQueue.main.async { completion.call() }
    }

    /// A `104 Upload Resumption Supported` tells us the server speaks the IETF draft, so the
    /// native resumable path is live for this task rather than the TUSKit fallback.
    @available(iOS 17.0, *)
    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didReceiveInformationalResponse response: HTTPURLResponse
    ) {
        guard response.statusCode == 104, let jobId = task.taskDescription else { return }
        log.debug("job \(jobId) negotiated native resumable upload")
        // Absence of this is the only signal that iOS and the server failed to agree on a draft
        // revision, in which case the transfer silently proceeds as NON-resumable. Recording it
        // lets the engine drive its own PATCH-based resume instead of trusting the system, and
        // makes the degradation visible in telemetry.
        events.noteNativeResumeSupported(jobId: jobId)
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard let jobId = task.taskDescription else { return }
        // Coalesced to ≤1 Hz per job (state machine I9). A multi-GB upload fires this constantly,
        // and forwarding every one of them across the RN bridge stalls the UI thread.
        progress.record(jobId: jobId, bytesSent: totalBytesSent, total: totalBytesExpectedToSend)
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        guard let jobId = task.taskDescription else { return }
        progress.flush(jobId: jobId)

        if let error = error as? URLError {
            // On iOS 17+ a failed upload can carry resume data. Its presence means "resumable
            // from the server's offset", not "start over" — persist it before reporting the error.
            if #available(iOS 17.0, *), let resumeData = error.uploadTaskResumeData {
                events.storeResumeData(jobId: jobId, data: resumeData)
            }
            events.send(jobId: jobId, event: .transportError(Self.classify(error), detail: error.localizedDescription))
            return
        }
        if let error {
            events.send(jobId: jobId, event: .transportError(.transient, detail: error.localizedDescription))
            return
        }

        guard let http = task.response as? HTTPURLResponse else {
            events.send(jobId: jobId, event: .transportError(.transient, detail: "no response"))
            return
        }
        switch http.statusCode {
        case 200...204:
            events.send(jobId: jobId, event: .transportComplete)
        case 404, 410:
            events.send(jobId: jobId, event: .gone)
        default:
            events.send(jobId: jobId,
                        event: .transportError(HTTPStatus.classify(http.statusCode), detail: "HTTP \(http.statusCode)"))
        }
    }

    /// Network handovers (Wi-Fi → cellular) surface here as `.networkConnectionLost` /
    /// `.notConnectedToInternet`. They are transient by definition: HEAD, then resume. Treating
    /// them as failures is what made the original AWS-SDK implementation feel broken on trains.
    private static func classify(_ error: URLError) -> ErrorClass {
        switch error.code {
        case .networkConnectionLost, .notConnectedToInternet, .timedOut,
             .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff:
            return .transient
        case .userAuthenticationRequired:
            return .auth
        case .cancelled:
            return .transient
        case .dataLengthExceedsMaximum:
            return .fatal
        default:
            return .transient
        }
    }
}

/// The single source of truth for HTTP status → retry policy on the Swift side. `TransportError`
/// `.http` defers to it (`ControlPlaneClient.swift`) rather than restating the table: the two are
/// read on different paths — session delegate and foreground control plane — and no conformance
/// vector covers status classification, so a divergence would ship silently.
public enum HTTPStatus {
    public static func classify(_ code: Int) -> ErrorClass {
        switch code {
        case 401, 403: return .auth
        case 409, 460: return .protocolError      // offset conflict / checksum mismatch
        case 412: return .protocolVersion         // interop version mismatch
        case 400, 413: return .fatal
        case 429, 500...599: return .transient
        default: return .fatal
        }
    }
}
