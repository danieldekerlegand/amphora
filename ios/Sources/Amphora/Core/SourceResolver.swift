import Foundation
import CryptoKit

/// Turns a caller-supplied URI into something the background session can send, copying only when
/// it must.
///
/// The decision ladder is the whole point (persistence-and-recovery.md §3): a real file URL costs
/// **zero** extra storage, because the background session uploads straight from it. Only a
/// `PHAsset` forces a copy — and that is the single iOS path where low storage can block an upload.
public actor SourceResolver {

    private let storage: StorageGovernor
    private let photos: any PhotosAssetSource

    public init(storage: StorageGovernor, photos: any PhotosAssetSource = SystemPhotosAssetSource()) {
        self.storage = storage
        self.photos = photos
    }

    public func probe(_ uri: String) throws -> Probe {
        if uri.hasPrefix("ph://") {
            let localId = String(uri.dropFirst("ph://".count))
            let asset = try photos.metadata(forLocalIdentifier: localId)
            let size = asset.estimatedSizeBytes
            return Probe(
                kind: .photosAsset,
                sizeBytes: size,
                fingerprint: Self.fingerprint(uri, size, asset.modificationDate ?? .distantPast)
            )
        }

        let url = URL(fileURLWithPath: uri.replacingOccurrences(of: "file://", with: ""))
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values.fileSize ?? 0)
        return Probe(
            kind: .file,
            sizeBytes: size,
            fingerprint: Self.fingerprint(uri, size, values.contentModificationDate ?? .distantPast)
        )
    }

    /// Cheap: (uri, size, mtime). Hashing 4 GB every launch costs minutes and battery for a check
    /// this already answers. See persistence-and-recovery.md §6.
    private static func fingerprint(_ uri: String, _ size: Int64, _ mtime: Date) -> String {
        let input = "\(uri)|\(size)|\(mtime.timeIntervalSince1970)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    public func isIntact(_ job: UploadJob) async -> Bool {
        // A staged copy that still exists is authoritative — the original may legitimately be gone
        // (a Photos asset deleted after we exported it) and the upload should still finish.
        if let staged = job.stagedPath, FileManager.default.fileExists(atPath: staged) { return true }
        guard let probe = try? probe(job.sourceUri) else { return false }
        return probe.fingerprint == job.fingerprint
    }

    /// Returns a staged file only when the source genuinely cannot be handed to the session
    /// directly. For `.file` this is always nil, which is the common and cheap path.
    public func stageIfRequired(_ job: UploadJob) async throws -> URL? {
        if let staged = job.stagedPath { return URL(fileURLWithPath: staged) }
        guard job.sourceKind == .photosAsset else { return nil }

        guard try await storage.reserveRemainder(jobId: job.id, bytes: job.sizeBytes) != nil else {
            throw TransportError.remainderStagingDenied(needed: job.sizeBytes)
        }
        let localId = String(job.sourceUri.dropFirst("ph://".count))
        return try await storage.exportPhotosAsset(localId, jobId: job.id)
    }

    public struct Probe: Sendable {
        public let kind: SourceKind
        public let sizeBytes: Int64
        public let fingerprint: String
    }
}
