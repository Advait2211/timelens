import Foundation
import SQLite3

/// A thin wrapper over one SQLite connection. Not thread-safe on its own: `ActivityStore`
/// confines it to a serial queue.
final class Database {
    enum Value {
        case int(Int64)
        case double(Double)
        case text(String)
        case null
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw Failure(message: "Couldn't open the database: \(message)")
        }
        sqlite3_busy_timeout(db, 2000)
        try exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = OFF;")
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(db)
    }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw Failure(message: message)
        }
    }

    var userVersion: Int {
        get {
            var version = 0
            query("PRAGMA user_version") { version = Int($0.int(0)) }
            return version
        }
        set { try? exec("PRAGMA user_version = \(newValue)") }
    }

    func transaction(_ body: () -> Void) {
        try? exec("BEGIN IMMEDIATE")
        body()
        try? exec("COMMIT")
    }

    @discardableResult
    func run(_ sql: String, _ args: [Value] = []) -> Bool {
        guard let statement = prepare(sql) else { return false }
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        bind(statement, args)
        let result = sqlite3_step(statement)
        return result == SQLITE_DONE || result == SQLITE_ROW
    }

    func query(_ sql: String, _ args: [Value] = [], row: (Row) -> Void) {
        guard let statement = prepare(sql) else { return }
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        bind(statement, args)
        while sqlite3_step(statement) == SQLITE_ROW {
            row(Row(statement: statement))
        }
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(db) }

    var lastError: String { String(cString: sqlite3_errmsg(db)) }

    struct Row {
        let statement: OpaquePointer

        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func text(_ column: Int32) -> String {
            guard let pointer = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: pointer)
        }
        func optionalText(_ column: Int32) -> String? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(column)
        }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    }

    // MARK: Plumbing

    /// Statements are cached by SQL text; most queries run over and over.
    private func prepare(_ sql: String) -> OpaquePointer? {
        if let cached = statements[sql] { return cached }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil) == SQLITE_OK, let statement else {
            NSLog("TimeLens SQL error: %@ — %@", lastError, sql)
            return nil
        }
        statements[sql] = statement
        return statement
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ statement: OpaquePointer, _ values: [Value]) {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let .int(number): sqlite3_bind_int64(statement, position, number)
            case let .double(number): sqlite3_bind_double(statement, position, number)
            case let .text(text): sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case .null: sqlite3_bind_null(statement, position)
            }
        }
    }
}
