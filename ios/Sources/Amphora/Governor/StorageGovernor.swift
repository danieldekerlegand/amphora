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

    private let capacityProvider: @Sendable () -> Int64
    private var reservations: [String: Reservation] = [:]
    private var lastSample: StoragePressure = .ok

    public init(capacityProvider: @escaping @Sendable () -> Int64 = {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }) {
        self.capacityProvider = capacityProvider
    }

    /// The number Apple tells you to use for content the user asked for and expects to keep —
    /// as opposed to `volumeAvailableCapacityForOpportunisticUsage`, which is for prefetching.
    public func availableForImportantUsage() -> Int64 {
        capacityProvider()
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
        let input = try FileHandle(forReadingFrom: source)
        var output: FileHandle?
        var completed = false
        defer {
            try? input.close()
            try? output?.close()
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }

        let end = input.seekToEndOfFile()
        guard offset >= 0, UInt64(offset) <= end else { throw StorageError.invalidSourceRange }
        try input.seek(toOffset: UInt64(offset))

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw StorageError.exportFailed
        }
        output = try FileHandle(forWritingTo: destination)
        try output?.truncate(atOffset: 0)

        let chunkSize: Int64 = 1024 * 1024
        var remaining = Int64(end) - offset
        while remaining > 0 {
            guard sample() != .critical,
                  availableForImportantUsage() >= remaining + headroom else {
                throw StorageError.pressureRose
            }

            let chunk = try input.read(upToCount: Int(min(chunkSize, remaining))) ?? Data()
            guard !chunk.isEmpty else { throw StorageError.exportFailed }
            try output?.write(contentsOf: chunk)
            remaining -= Int64(chunk.count)
        }
        completed = true
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
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject,
              let resource = PHAssetResource.assetResources(for: asset).first else {
            throw StorageError.exportFailed
        }

        let bytes = Self.resourceSize(resource)
        let reservation: Reservation
        if let existing = reservations[jobId] {
            reservation = existing
        } else {
            guard let acquired = try reserveRemainder(jobId: jobId, bytes: bytes) else {
                throw StorageError.stagingDenied
            }
            reservation = acquired
        }

        try? FileManager.default.removeItem(at: reservation.url)
        do {
            try await PhotosResourceExporter().write(resource: resource, to: reservation.url)
            return reservation.url
        } catch {
            release(jobId: jobId)
            throw StorageError.exportFailed
        }
    }

    private static func resourceSize(_ resource: PHAssetResource) -> Int64 {
        if let size = resource.value(forKey: "fileSize") as? Int64 { return size }
        if let size = resource.value(forKey: "fileSize") as? NSNumber { return size.int64Value }
        return 0
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

private struct PhotosResourceExporter: Sendable {
    func write(resource: PHAssetResource, to url: URL) async throws {
        let manager = PHAssetResourceManager.default()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            manager.writeData(for: resource, toFile: url, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

public enum StoragePressure: Sendable { case ok, low, critical }
public enum StorageError: Error { case pressureRose, exportFailed, stagingDenied, invalidSourceRange }
