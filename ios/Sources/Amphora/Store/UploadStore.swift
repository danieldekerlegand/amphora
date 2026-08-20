import Foundation

/// The durable job registry. See docs/reference/persistence-and-recovery.md §2.
///
/// Backed by SQLite rather than Core Data, for one reason that outweighs the convenience: the
/// lease (state-machine I8) needs a genuine compare-and-set, and `tryAcquireLease` below is a
/// single conditional UPDATE. Expressing that through Core Data's object graph invites exactly
/// the read-modify-write race the lease exists to prevent.
public protocol UploadStore: Sendable {

    func get(id: String) async throws -> UploadJob?
    func all() async throws -> [UploadJob]

    /// The reconciler's working set: everything not durably finished.
    func unfinished() async throws -> [UploadJob]

    /// Cancelations whose DELETE never reached the server. Retried opportunistically.
    func pendingTerminations() async throws -> [UploadJob]

    func liveStagedPaths() async throws -> [String]

    func insert(_ job: UploadJob) async throws
    func update(id: String, _ mutate: @Sendable (inout UploadJob) -> Void) async throws

    /// Compare-and-set. Returns false when another runner holds the lease.
    func tryAcquireLease(id: String, token: String, expiresAt: Date, now: Date) async throws -> Bool
    func releaseLease(id: String, token: String) async throws
    func renewLease(id: String, token: String, expiresAt: Date) async throws
    func breakStaleLeases(asOf: Date) async throws

    /// iOS 17 resume-data blobs, kept out of the row itself — they can reach hundreds of KB and
    /// would bloat every query that reads the registry.
    func storeResumeData(id: String, data: Data) async throws
    func loadResumeData(id: String) async throws -> Data?

    /// Completed rows are retained, not deleted — "did it upload last Tuesday?" is a real question.
    func pruneCompleted(before: Date) async throws
}
