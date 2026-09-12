import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite implementation of the durable upload registry.
public actor SQLiteUploadStore: UploadStore {

    /// Owns the sqlite handle, and is the only thing that closes it.
    ///
    /// The handle used to be stored on the actor directly, with `deinit { sqlite3_close(database) }`
    /// alongside it. An actor's `deinit` is nonisolated, so reading a non-`Sendable`
    /// `OpaquePointer` from there is an error in the Swift 6 language mode (surfaced under
    /// `-strict-concurrency=complete`, tasklist `140`). Giving the lifetime to a plain class whose
    /// *own* deinit does the close answers the question rather than asserting past it: a class
    /// deinit is under no isolation, the actor's last reference is the only reference, and the
    /// handle is closed exactly once when the store goes away.
    private final class Connection: @unchecked Sendable {
        let handle: OpaquePointer
        init(_ handle: OpaquePointer) { self.handle = handle }
        deinit { sqlite3_close(handle) }
    }

    private let connection: Connection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw StoreError.openFailed(String(cString: sqlite3_errmsg(handle)))
        }
        connection = Connection(handle)
        sqlite3_busy_timeout(connection.handle, 5_000)
        let schema = """
            PRAGMA foreign_keys = ON;
            CREATE TABLE IF NOT EXISTS upload_jobs (
                id TEXT PRIMARY KEY NOT NULL,
                payload BLOB NOT NULL,
                state TEXT NOT NULL,
                remote_terminated INTEGER NOT NULL,
                staged_path TEXT,
                owner_token TEXT,
                lease_expires_at REAL,
                completed_at REAL
            );
            CREATE TABLE IF NOT EXISTS resume_data (
                id TEXT PRIMARY KEY NOT NULL REFERENCES upload_jobs(id) ON DELETE CASCADE,
                data BLOB NOT NULL
            );
            """
        guard sqlite3_exec(connection.handle, schema, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(connection.handle)))
        }
    }

    public func get(id: String) async throws -> UploadJob? {
        try load("SELECT payload FROM upload_jobs WHERE id = ?", bindings: [id]).first
    }

    public func all() async throws -> [UploadJob] {
        try load("SELECT payload FROM upload_jobs ORDER BY rowid")
    }

    public func unfinished() async throws -> [UploadJob] {
        try load("SELECT payload FROM upload_jobs WHERE state NOT IN ('completed', 'failed', 'canceled') ORDER BY rowid")
    }

    public func pendingTerminations() async throws -> [UploadJob] {
        try load("SELECT payload FROM upload_jobs WHERE state = 'canceled' AND remote_terminated = 0 ORDER BY rowid")
    }

    public func liveStagedPaths() async throws -> [String] {
        let statement = try prepare("SELECT staged_path FROM upload_jobs WHERE staged_path IS NOT NULL AND state NOT IN ('completed', 'failed', 'canceled')")
        defer { sqlite3_finalize(statement) }
        var paths: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) { paths.append(String(cString: value)) }
        }
        return paths
    }

    public func insert(_ job: UploadJob) async throws {
        let payload = try encoder.encode(job)
        let statement = try prepare("INSERT INTO upload_jobs (id, payload, state, remote_terminated, staged_path, owner_token, lease_expires_at, completed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(job.id, at: 1, in: statement)
        try bind(payload, at: 2, in: statement)
        try bind(job.state.rawValue, at: 3, in: statement)
        try bind(job.remoteTerminated ? 1 : 0, at: 4, in: statement)
        try bind(job.stagedPath, at: 5, in: statement)
        try bind(job.ownerToken, at: 6, in: statement)
        try bind(job.leaseExpiresAt?.timeIntervalSince1970, at: 7, in: statement)
        try bind(job.completedAt?.timeIntervalSince1970, at: 8, in: statement)
        try step(statement)
    }

    public func update(id: String, _ mutate: @Sendable (inout UploadJob) -> Void) async throws {
        guard var job = try await get(id: id) else { throw StoreError.notFound(id) }
        mutate(&job)
        let payload = try encoder.encode(job)
        let statement = try prepare("UPDATE upload_jobs SET payload = ?, state = ?, remote_terminated = ?, staged_path = ?, owner_token = ?, lease_expires_at = ?, completed_at = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(payload, at: 1, in: statement)
        try bind(job.state.rawValue, at: 2, in: statement)
        try bind(job.remoteTerminated ? 1 : 0, at: 3, in: statement)
        try bind(job.stagedPath, at: 4, in: statement)
        try bind(job.ownerToken, at: 5, in: statement)
        try bind(job.leaseExpiresAt?.timeIntervalSince1970, at: 6, in: statement)
        try bind(job.completedAt?.timeIntervalSince1970, at: 7, in: statement)
        try bind(id, at: 8, in: statement)
        try step(statement)
    }

    public func tryAcquireLease(id: String, token: String, expiresAt: Date, now: Date) async throws -> Bool {
        let statement = try prepare("UPDATE upload_jobs SET owner_token = ?, lease_expires_at = ? WHERE id = ? AND (owner_token IS NULL OR lease_expires_at IS NULL OR lease_expires_at <= ?)")
        defer { sqlite3_finalize(statement) }
        try bind(token, at: 1, in: statement)
        try bind(expiresAt.timeIntervalSince1970, at: 2, in: statement)
        try bind(id, at: 3, in: statement)
        try bind(now.timeIntervalSince1970, at: 4, in: statement)
        try step(statement)
        return sqlite3_changes(connection.handle) == 1
    }

    public func releaseLease(id: String, token: String) async throws {
        try execute("UPDATE upload_jobs SET owner_token = NULL, lease_expires_at = NULL WHERE id = ? AND owner_token = ?", bindings: [id, token])
    }

    public func renewLease(id: String, token: String, expiresAt: Date) async throws {
        try execute("UPDATE upload_jobs SET lease_expires_at = ? WHERE id = ? AND owner_token = ?", bindings: [expiresAt.timeIntervalSince1970, id, token])
    }

    public func breakStaleLeases(asOf: Date) async throws {
        try execute("UPDATE upload_jobs SET owner_token = NULL, lease_expires_at = NULL WHERE lease_expires_at IS NOT NULL AND lease_expires_at <= ?", bindings: [asOf.timeIntervalSince1970])
    }

    public func storeResumeData(id: String, data: Data) async throws {
        try execute("INSERT INTO resume_data (id, data) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data", bindings: [id, data])
    }

    public func loadResumeData(id: String) async throws -> Data? {
        let statement = try prepare("SELECT data FROM resume_data WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let bytes = sqlite3_column_blob(statement, 0)
        return Data(bytes: bytes!, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    public func pruneCompleted(before date: Date) async throws {
        try execute("DELETE FROM upload_jobs WHERE state = 'completed' AND completed_at IS NOT NULL AND completed_at < ?", bindings: [date.timeIntervalSince1970])
    }

    public enum StoreError: Error, LocalizedError {
        case openFailed(String)
        case sqlite(String)
        case notFound(String)

        public var errorDescription: String? {
            switch self {
            case .openFailed(let message), .sqlite(let message): return message
            case .notFound(let id): return "Upload job not found: \(id)"
            }
        }
    }

    private func load(_ sql: String, bindings: [Any] = []) throws -> [UploadJob] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindAll(bindings, to: statement)
        var jobs: [UploadJob] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let bytes = sqlite3_column_blob(statement, 0)
            jobs.append(try decoder.decode(UploadJob.self, from: Data(bytes: bytes!, count: Int(sqlite3_column_bytes(statement, 0)))))
        }
        return jobs
    }

    private func execute(_ sql: String, bindings: [Any] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindAll(bindings, to: statement)
        try step(statement)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(connection.handle)))
        }
        return statement
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(connection.handle))) }
    }

    private func bindAll(_ values: [Any], to statement: OpaquePointer) throws {
        for (index, value) in values.enumerated() { try bind(value, at: index + 1, in: statement) }
    }

    private func bind(_ value: Any?, at index: Int, in statement: OpaquePointer) throws {
        let result: Int32
        switch value {
        case nil: result = sqlite3_bind_null(statement, Int32(index))
        case let value as String: result = sqlite3_bind_text(statement, Int32(index), value, -1, sqliteTransient)
        case let value as Data: result = value.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(index), $0.baseAddress, Int32(value.count), sqliteTransient) }
        case let value as Double: result = sqlite3_bind_double(statement, Int32(index), value)
        case let value as Int: result = sqlite3_bind_int(statement, Int32(index), Int32(value))
        default: throw StoreError.sqlite("Unsupported SQLite binding")
        }
        guard result == SQLITE_OK else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(connection.handle))) }
    }
}
