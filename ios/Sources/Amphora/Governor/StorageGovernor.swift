import Foundation
import Photos

/// The component no existing upload library has.
///
/// iOS gives less than Android here: there is no `allocateBytes` equivalent, so space cannot be
/// *reserved* — only measured and re-measured. The mitigations are therefore placement and
/// vigilance: stage where the OS will not reclaim, and keep sampling because free space on a
/// phone moves fast (a video recording, a system update download, another app's cache).
public actor StorageGovernor {

    /// Never drive the device to zero; leave the user room to breathe.
    private let headroom: Int64 = 512 * 1024 * 1024

    private var reservations: [String: Reservation] = [:]
    private var lastSample: StoragePressure = .ok

    public init() {}

    /// The number Apple tells you to use for content the user asked for and expects to keep —
    /// as opposed to `volumeAvailableCapacityForOpportunisticUsage`, which is for prefetching.
    public func availableForImportantUsage() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    public func sample() -> StoragePressure {
        let available = availableForImportantUsage()
        let pressure: StoragePressure
        switch available {
        case ..<headroom: pressure = .critical
        case ..<(headroom * 3): pressure = .low
        default: pressure = .ok
        }
        lastSample = pressure
        return pressure
    }

    /// Space for a staged copy or a pre-iOS-17 remainder. Returns nil when the device genuinely
    /// cannot host it, which the state machine turns into `.blocked` rather than a failure —
    /// free space is a moving target and this job may well run in ten minutes.
    public func reserveRemainder(jobId: String, bytes: Int64) throws -> Reservation? {
        guard bytes + headroom <= availableForImportantUsage() else { return nil }

        let url = try stagingDirectory().appendingPathComponent("\(jobId).part")
        let reservation = Reservation(jobId: jobId, url: url, bytes: bytes, acquiredAt: Date())
        reservations[jobId] = reservation
        return reservation
    }

    public func release(jobId: String) {
        guard let reservation = reservations.removeValue(forKey: jobId) else { return }
        try? FileManager.default.removeItem(at: reservation.url)
    }

    /// Copies `[offset, end)` out of the source. Chunked so a low-storage signal mid-write aborts
    /// promptly instead of after gigabytes.
    public func writeRemainder(from source: URL, offset: Int64, to destination: URL) throws {
        // TODO(impl): FileHandle seek + chunked read/write, re-sampling pressure every N MB and
        //   throwing `StorageError.pressureRose` so the caller can block the job cleanly.
        fatalError("unimplemented")
    }

    /// **Application Support, never `Caches` or `tmp`.**
    ///
    /// Apple's guarantee that `Caches` is not purged "while your app is running" does not help a
    /// background upload — the app is *suspended*, which is exactly when purging happens. This
    /// single placement decision is the direct fix for the original corruption bug.
    public func stagingDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        var dir = base.appendingPathComponent("Amphora/Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Staged uploads are reproducible from the source; keeping them out of iCloud backup
        // avoids charging the user's backup quota for our scratch space.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    /// Export a `PHAsset` to a real file. Unavoidable — Photos assets are not seekable file URLs,
    /// and this is the one source kind that always costs a full copy.
    public func exportPhotosAsset(_ localIdentifier: String, jobId: String) async throws -> URL {
        // TODO(impl): PHAssetResourceManager.writeData(for:toFile:) with
        //   `isNetworkAccessAllowed = true` for iCloud-offloaded originals, reserving first.
        //   Note this can itself take minutes for a large 4K video and must be cancelable.
        fatalError("unimplemented")
    }

    /// Reclaim staged files with no owning job row. Crash-path cleanup for state-machine I5;
    /// called by the reconciler, which is the only component that knows which rows are live.
    public func collectOrphans(liveStagedPaths: Set<String>) throws -> Int {
        let dir = try stagingDirectory()
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        var removed = 0
        for url in contents where !liveStagedPaths.contains(url.path) {
            try? FileManager.default.removeItem(at: url)
            removed += 1
        }
        return removed
    }

    public struct Reservation: Sendable {
        public let jobId: String
        public let url: URL
        public let bytes: Int64
        public let acquiredAt: Date
    }
}

public enum StoragePressure: Sendable { case ok, low, critical }
public enum StorageError: Error { case pressureRose, exportFailed }
