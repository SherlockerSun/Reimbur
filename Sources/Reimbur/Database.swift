import Foundation
import CSQLite

struct ReimburError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

final class Database {
    private var handle: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    let root: URL
    var attachmentDirectory: URL { root.appendingPathComponent("Attachments", isDirectory: true) }

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
        guard sqlite3_open_v2(root.appendingPathComponent("reimbur.sqlite3").path, &handle,
                              SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw ReimburError("无法打开 SQLite 数据库，请检查数据目录的访问权限。")
        }
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("CREATE TABLE IF NOT EXISTS claims (id TEXT PRIMARY KEY, title TEXT NOT NULL, kind TEXT NOT NULL, updated_at REAL NOT NULL, payload BLOB NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS claims_updated ON claims(updated_at DESC)")
        try execute("PRAGMA user_version=1")
    }

    deinit { sqlite3_close(handle) }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func error() -> ReimburError {
        ReimburError("数据库操作失败：\(String(cString: sqlite3_errmsg(handle)))")
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &query, nil) == SQLITE_OK, let query else { throw error() }
        return query
    }
    private func bind(_ value: String, to index: Int32, in query: OpaquePointer) {
        _ = value.withCString { sqlite3_bind_text(query, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }

    func load() throws -> [Claim] {
        let query = try statement("SELECT payload FROM claims ORDER BY updated_at DESC")
        defer { sqlite3_finalize(query) }
        var claims: [Claim] = []
        var result = sqlite3_step(query)
        while result == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(query, 0))
            guard let bytes = sqlite3_column_blob(query, 0), count > 0 else { throw ReimburError("记录数据为空，未覆盖原数据库。") }
            let claim = try decoder.decode(Claim.self, from: Data(bytes: bytes, count: count))
            claims.append(claim)
            result = sqlite3_step(query)
        }
        guard result == SQLITE_DONE else { throw error() }
        return claims
    }

    func save(_ claim: Claim) throws {
        let query = try statement("INSERT INTO claims(id,title,kind,updated_at,payload) VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,kind=excluded.kind,updated_at=excluded.updated_at,payload=excluded.payload")
        defer { sqlite3_finalize(query) }
        bind(claim.id.uuidString, to: 1, in: query)
        bind(claim.title, to: 2, in: query)
        bind(claim.kind.rawValue, to: 3, in: query)
        sqlite3_bind_double(query, 4, claim.updatedAt.timeIntervalSince1970)
        let data = try encoder.encode(claim)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(query, 5, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw error() }
    }

    func delete(ids: Set<UUID>) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for id in ids { try delete(id) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func delete(_ id: UUID) throws {
        let query = try statement("DELETE FROM claims WHERE id=?")
        defer { sqlite3_finalize(query) }
        bind(id.uuidString, to: 1, in: query)
        guard sqlite3_step(query) == SQLITE_DONE else { throw error() }
    }
}
