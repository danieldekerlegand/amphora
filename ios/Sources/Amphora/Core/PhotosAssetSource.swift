import Foundation
import Photos

/// Every Photos touchpoint on the `ph://` path goes through here, and nowhere else.
///
/// Two callers, one seam: `SourceResolver.probe` needs the size and modification date to build a
/// job row and a fingerprint, and `StorageGovernor.exportPhotosAsset` needs the bytes written to a
/// file. Both are unreachable without a real Photos library and a real asset, which is why the
/// `ph://` path — the one source this library is *required* to copy — had never been exercised.
///
/// **The seam is told its destination.** `export` takes the URL `StorageGovernor` reserved and
/// returns nothing, so no implementation, real or test, can choose where the copy lands. That
/// placement (`Application Support/Amphora/Staging`, never `Caches`) is the direct fix for the
/// original corruption bug; a seam that let its implementer pick a path would stop proving it.
public protocol PhotosAssetSource: Sendable {

    /// Throws when the identifier names no asset — the caller turns that into a missing source
    /// rather than an empty upload.
    func metadata(forLocalIdentifier localIdentifier: String) throws -> PhotosAssetMetadata

    /// Copies the asset's primary resource to `destination`, which the caller has already
    /// reserved space for.
    func export(localIdentifier: String, to destination: URL) async throws
}

/// What the `ph://` path needs to know about an asset, and nothing more. Deliberately not a
/// `PHAsset`: the point of the seam is that no caller holds a Photos type.
public struct PhotosAssetMetadata: Sendable {

    /// `PHAsset` reports no byte size directly. The resource's `fileSize` is the closest thing,
    /// and it is only an estimate for iCloud-offloaded originals — which is why the state machine
    /// takes `sizeBytes` from `sourceResolved` after export rather than trusting this.
    public let estimatedSizeBytes: Int64

    /// The cheap change signal. Photos does not expose a stable content hash and computing one
    /// would mean reading the whole asset.
    public let modificationDate: Date?

    public init(estimatedSizeBytes: Int64, modificationDate: Date?) {
        self.estimatedSizeBytes = estimatedSizeBytes
        self.modificationDate = modificationDate
    }
}

/// The default — today's `PHAsset` code, moved rather than rewritten. This is the only file in the
/// package that imports Photos.
public struct SystemPhotosAssetSource: PhotosAssetSource {

    public init() {}

    public func metadata(forLocalIdentifier localIdentifier: String) throws -> PhotosAssetMetadata {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
        else { throw StorageError.exportFailed }
        return PhotosAssetMetadata(
            estimatedSizeBytes: Self.estimatedSize(of: asset),
            modificationDate: asset.modificationDate
        )
    }

    public func export(localIdentifier: String, to destination: URL) async throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject,
              let resource = PHAssetResource.assetResources(for: asset).first else {
            throw StorageError.exportFailed
        }

        let manager = PHAssetResourceManager.default()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            manager.writeData(for: resource, toFile: destination, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Both former readers, merged: `SourceResolver` scanned every resource for an `Int64`,
    /// `StorageGovernor` read only the first but also accepted an `NSNumber`. One seam cannot keep
    /// two answers for one question, so this accepts either representation from any resource.
    private static func estimatedSize(of asset: PHAsset) -> Int64 {
        for resource in PHAssetResource.assetResources(for: asset) {
            if let size = resource.value(forKey: "fileSize") as? Int64 { return size }
            if let size = resource.value(forKey: "fileSize") as? NSNumber { return size.int64Value }
        }
        return 0
    }
}
