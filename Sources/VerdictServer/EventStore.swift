import Foundation
import SQLite3
import VerdictCore

/// The SQLite substrate for dataflow mode (SPEC §12): reads `events`, writes `decisions`. Thin wrapper
/// over the SDK's SQLite3 (no dependency). Not Sendable; the `Watcher` actor owns one and never shares it.
final class EventStore {
    struct Error: Swift.Error, CustomStringConvertible { let description: String }

    struct Event: Sendable {
        let id: Int64
        let type: String
        let state: String
    }

    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)   // SQLITE_TRANSIENT

    init(path: String) throws {
        let rc = sqlite3_open(path, &db)
        guard rc == SQLITE_OK, db != nil else {
            throw Error(description: "cannot open \(path): \(message)")
        }
        sqlite3_busy_timeout(db, 3000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
        try ensureSchema()
    }

    deinit { sqlite3_close(db) }

    private var message: String { String(cString: sqlite3_errmsg(db)) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? message
            sqlite3_free(err)
            throw Error(description: "exec failed: \(m)  [\(sql.prefix(80))]")
        }
    }

    /// Creates the two tables if absent. Never drops or alters an existing schema (SPEC §12.1).
    func ensureSchema() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS events (
              id INTEGER PRIMARY KEY, type TEXT NOT NULL, state TEXT NOT NULL,
              status TEXT NOT NULL DEFAULT 'pending', created_at TEXT, processed_at TEXT);
            CREATE INDEX IF NOT EXISTS events_status ON events(status, id);
            CREATE TABLE IF NOT EXISTS decisions (
              event_id INTEGER NOT NULL, question_id TEXT NOT NULL, type TEXT NOT NULL,
              answer TEXT, confidence REAL, confidence_kind TEXT NOT NULL, probabilities TEXT,
              backend TEXT NOT NULL, failed INTEGER NOT NULL DEFAULT 0, code TEXT, created_at TEXT,
              PRIMARY KEY (event_id, question_id));
            """)
    }

    /// Up to `limit` pending events, oldest first.
    func pending(limit: Int) throws -> [Event] {
        let stmt = try prepare("SELECT id, type, state FROM events WHERE status='pending' ORDER BY id LIMIT ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [Event] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Event(id: sqlite3_column_int64(stmt, 0),
                             type: text(stmt, 1) ?? "", state: text(stmt, 2) ?? ""))
        }
        return out
    }

    func count(status: String) throws -> Int {
        let stmt = try prepare("SELECT count(*) FROM events WHERE status=?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, status)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// One row to write to `decisions`.
    struct DecisionRow {
        let questionID: String
        let type: String
        let answer: String?
        let confidence: Double?
        let confidenceKind: String
        let probabilitiesJSON: String?
        let backend: String
        let failed: Bool
        let code: String?
    }

    /// Write every decision for one event and mark it `done`, atomically (SPEC §12.3). A crash before
    /// COMMIT leaves the event `pending` with no partial rows.
    func complete(eventID: Int64, rows: [DecisionRow], now: String) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            let ins = try prepare("""
                INSERT INTO decisions (event_id, question_id, type, answer, confidence, confidence_kind,
                  probabilities, backend, failed, code, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(event_id, question_id) DO UPDATE SET
                  type=excluded.type, answer=excluded.answer, confidence=excluded.confidence,
                  confidence_kind=excluded.confidence_kind, probabilities=excluded.probabilities,
                  backend=excluded.backend, failed=excluded.failed, code=excluded.code, created_at=excluded.created_at
                """)
            defer { sqlite3_finalize(ins) }
            for r in rows {
                sqlite3_reset(ins); sqlite3_clear_bindings(ins)
                sqlite3_bind_int64(ins, 1, eventID)
                bind(ins, 2, r.questionID); bind(ins, 3, r.type); bind(ins, 4, r.answer)
                if let c = r.confidence { sqlite3_bind_double(ins, 5, c) } else { sqlite3_bind_null(ins, 5) }
                bind(ins, 6, r.confidenceKind); bind(ins, 7, r.probabilitiesJSON); bind(ins, 8, r.backend)
                sqlite3_bind_int(ins, 9, r.failed ? 1 : 0); bind(ins, 10, r.code); bind(ins, 11, now)
                guard sqlite3_step(ins) == SQLITE_DONE else { throw Error(description: "insert decision failed: \(message)") }
            }
            try setStatus(eventID: eventID, status: "done", now: now)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func setStatus(eventID: Int64, status: String, now: String) throws {
        let stmt = try prepare("UPDATE events SET status=?, processed_at=? WHERE id=?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, status); bind(stmt, 2, now); sqlite3_bind_int64(stmt, 3, eventID)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Error(description: "update status failed: \(message)") }
    }

    // Test/consumer helpers.
    func insertEvent(type: String, state: String, now: String = ISO8601DateFormatter().string(from: Date())) throws -> Int64 {
        let stmt = try prepare("INSERT INTO events (type, state, status, created_at) VALUES (?,?, 'pending', ?)")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, type); bind(stmt, 2, state); bind(stmt, 3, now)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Error(description: "insert event failed: \(message)") }
        return sqlite3_last_insert_rowid(db)
    }

    func decisions(eventID: Int64) throws -> [DecisionRow] {
        let stmt = try prepare("""
            SELECT question_id, type, answer, confidence, confidence_kind, probabilities, backend, failed, code
            FROM decisions WHERE event_id=? ORDER BY question_id
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, eventID)
        var out: [DecisionRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(DecisionRow(
                questionID: text(stmt, 0) ?? "", type: text(stmt, 1) ?? "", answer: text(stmt, 2),
                confidence: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 3),
                confidenceKind: text(stmt, 4) ?? "", probabilitiesJSON: text(stmt, 5), backend: text(stmt, 6) ?? "",
                failed: sqlite3_column_int(stmt, 7) == 1, code: text(stmt, 8)))
        }
        return out
    }

    func status(eventID: Int64) throws -> String? {
        let stmt = try prepare("SELECT status FROM events WHERE id=?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, eventID)
        return sqlite3_step(stmt) == SQLITE_ROW ? text(stmt, 0) : nil
    }

    // MARK: raw helpers

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw Error(description: "prepare failed: \(message)  [\(sql.prefix(60))]")
        }
        return stmt
    }
    private func bind(_ stmt: OpaquePointer?, _ i: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, i, value, -1, Self.transient) } else { sqlite3_bind_null(stmt, i) }
    }
    private func text(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }
}
