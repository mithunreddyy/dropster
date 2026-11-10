import Foundation
import SQLite3

public struct HistoryEntry: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var date: Date
    public var source: String
    public var output: String?
    public var operation: String
    public var inputBytes: Int64
    public var outputBytes: Int64
    public var outcome: String
    public var duration: Double
}

public struct HistoryTotals: Sendable, Hashable {
    public var files: Int
    public var savedBytes: Int64
    public init(files: Int, savedBytes: Int64) { self.files = files; self.savedBytes = savedBytes }
}

/// Local-only record of completed work, stored in SQLite under Application Support.
public final class HistoryStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw DropsterError.encodeFailed("cannot open history database")
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("""
            CREATE TABLE IF NOT EXISTS history (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              date REAL NOT NULL,
              source TEXT NOT NULL,
              output TEXT,
              operation TEXT NOT NULL,
              input_bytes INTEGER NOT NULL,
              output_bytes INTEGER NOT NULL,
              outcome TEXT NOT NULL,
              duration REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS history_date ON history(date DESC);
            """)
    }

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dropster/history.sqlite")
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DropsterError.encodeFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func record(source: URL, operation: FileOperation, result: ProcessingResult) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO history (date, source, output, operation, input_bytes, output_bytes, outcome, duration) VALUES (?,?,?,?,?,?,?,?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, source.path, -1, Self.transient)
        if let o = result.output { sqlite3_bind_text(stmt, 3, o.path, -1, Self.transient) } else { sqlite3_bind_null(stmt, 3) }
        sqlite3_bind_text(stmt, 4, operation.label, -1, Self.transient)
        sqlite3_bind_int64(stmt, 5, result.inputBytes)
        sqlite3_bind_int64(stmt, 6, result.outcome == .written ? result.producedBytes : result.inputBytes)
        sqlite3_bind_text(stmt, 7, result.outcome.rawValue, -1, Self.transient)
        sqlite3_bind_double(stmt, 8, result.duration)
        sqlite3_step(stmt)
    }

    public func recent(limit: Int = 200) -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        let sql = "SELECT id, date, source, output, operation, input_bytes, output_bytes, outcome, duration FROM history ORDER BY date DESC LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [HistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
            out.append(HistoryEntry(id: sqlite3_column_int64(stmt, 0),
                                    date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                                    source: text(2) ?? "", output: text(3), operation: text(4) ?? "",
                                    inputBytes: sqlite3_column_int64(stmt, 5), outputBytes: sqlite3_column_int64(stmt, 6),
                                    outcome: text(7) ?? "", duration: sqlite3_column_double(stmt, 8)))
        }
        return out
    }

    public func totals() -> HistoryTotals {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*), COALESCE(SUM(MAX(input_bytes - output_bytes, 0)), 0) FROM history WHERE outcome = 'written' AND operation != 'Unpack'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return HistoryTotals(files: 0, savedBytes: 0) }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return HistoryTotals(files: 0, savedBytes: 0) }
        return HistoryTotals(files: Int(sqlite3_column_int(stmt, 0)), savedBytes: sqlite3_column_int64(stmt, 1))
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? exec("DELETE FROM history;")
    }
}
