import Foundation
import TimeLensCore

enum EventKind: String, CaseIterable {
    /// Coming back to the Mac after it was locked, asleep or the display was off.
    case pickup
    case lock, unlock, sleep, wake, screenOff, screenOn
    case idle, resume
    case limitWarning, limitReached
    case focusBlocked
    case breakReminder
}

struct EventRecord: Hashable {
    let time: Double
    let kind: EventKind
    let app: String
    let site: String
    let info: String
}

struct UsageLimit: Identifiable, Hashable, Codable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case app, site, category
        var id: String { rawValue }
        var title: String {
            switch self {
            case .app: "App"
            case .site: "Website"
            case .category: "Category"
            }
        }
    }

    var id: Int64 = 0
    var kind: Kind
    var target: String
    var minutes: Int
    /// Calendar weekdays it applies on, bit (weekday − 1): Sunday = 1, Monday = 2, … Saturday = 64.
    var days: Int = 127
    var enabled: Bool = true

    func applies(on date: Date, calendar: Calendar = .current) -> Bool {
        days & (1 << (calendar.component(.weekday, from: date) - 1)) != 0
    }

    var seconds: Double { Double(minutes) * 60 }
}

struct FocusRecord: Identifiable, Hashable {
    var id: Int64
    var start: Double
    var plannedEnd: Double
    var end: Double?
    var completed: Bool
    var blocked: Int
    var label: String

    var duration: Double { (end ?? Date().timeIntervalSince1970) - start }
    var plannedDuration: Double { plannedEnd - start }
}

struct AppRecord: Hashable {
    let id: String
    let name: String
    let path: String
    let declaredCategory: String
}

/// Time on one window title or page, for drill-downs.
struct TitleUsage: Identifiable, Hashable {
    let title: String
    let page: String
    let seconds: Double
    let lastSeen: Double
    var id: String { title + "|" + page }
}

/// Everything TimeLens records, in SQLite at ~/Library/Application Support/TimeLens. All
/// access goes through one serial queue.
final class ActivityStore: @unchecked Sendable {
    let url: URL
    private let db: Database
    private let queue = DispatchQueue(label: "com.advait.timelens.store", qos: .utility)
    private let calendar = Calendar.current

    init(url: URL) throws {
        self.url = url
        db = try Database(url: url)
        try migrate()
    }

    static var defaultURL: URL {
        supportDirectory.appendingPathComponent("timelens.sqlite")
    }

    static var demoURL: URL {
        supportDirectory.appendingPathComponent("demo.sqlite")
    }

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TimeLens", isDirectory: true)
    }

    private func migrate() throws {
        guard db.userVersion < 1 else { return }
        try db.exec("""
            BEGIN;
            CREATE TABLE IF NOT EXISTS usage (
                id    INTEGER PRIMARY KEY,
                start REAL NOT NULL,
                end   REAL NOT NULL,
                app   TEXT NOT NULL,
                site  TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS usage_start ON usage (start);
            CREATE TABLE IF NOT EXISTS detail (
                id    INTEGER PRIMARY KEY,
                start REAL NOT NULL,
                end   REAL NOT NULL,
                app   TEXT NOT NULL,
                site  TEXT NOT NULL DEFAULT '',
                title TEXT NOT NULL DEFAULT '',
                page  TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS detail_start ON detail (start);
            CREATE INDEX IF NOT EXISTS detail_app ON detail (app, start);
            CREATE INDEX IF NOT EXISTS detail_site ON detail (site, start);
            CREATE TABLE IF NOT EXISTS hourly (
                bucket  INTEGER NOT NULL,
                app     TEXT NOT NULL,
                site    TEXT NOT NULL,
                seconds REAL NOT NULL,
                PRIMARY KEY (bucket, app, site)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS events (
                id   INTEGER PRIMARY KEY,
                time REAL NOT NULL,
                kind TEXT NOT NULL,
                app  TEXT NOT NULL DEFAULT '',
                site TEXT NOT NULL DEFAULT '',
                info TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS events_time ON events (time);
            CREATE TABLE IF NOT EXISTS apps (
                id       TEXT PRIMARY KEY,
                name     TEXT NOT NULL,
                path     TEXT NOT NULL DEFAULT '',
                category TEXT NOT NULL DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS overrides (
                key      TEXT PRIMARY KEY,
                category TEXT,
                rating   INTEGER
            );
            CREATE TABLE IF NOT EXISTS limits (
                id      INTEGER PRIMARY KEY,
                kind    TEXT NOT NULL,
                target  TEXT NOT NULL,
                minutes INTEGER NOT NULL,
                days    INTEGER NOT NULL DEFAULT 127,
                enabled INTEGER NOT NULL DEFAULT 1
            );
            CREATE TABLE IF NOT EXISTS focus_sessions (
                id          INTEGER PRIMARY KEY,
                start       REAL NOT NULL,
                planned_end REAL NOT NULL,
                end         REAL,
                completed   INTEGER NOT NULL DEFAULT 0,
                blocked     INTEGER NOT NULL DEFAULT 0,
                label       TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS focus_start ON focus_sessions (start);
            PRAGMA user_version = 1;
            COMMIT;
            """)
    }

    // MARK: Queue

    func run<T>(_ body: @escaping (Database) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body(self.db)) }
        }
    }

    func runSync<T>(_ body: (Database) -> T) -> T {
        queue.sync { body(db) }
    }

    func runAsync(_ body: @escaping (Database) -> Void) {
        queue.async { body(self.db) }
    }

    // MARK: Segments

    /// The next free segment ids, so the tracker can name segments before they're written.
    func nextIDs() -> (usage: Int64, detail: Int64) {
        runSync { db in
            var usage: Int64 = 0
            var detail: Int64 = 0
            db.query("SELECT IFNULL(MAX(id), 0) FROM usage") { usage = $0.int(0) }
            db.query("SELECT IFNULL(MAX(id), 0) FROM detail") { detail = $0.int(0) }
            return (usage + 1, detail + 1)
        }
    }

    /// Writes the tracker's changes and rebuilds the hourly rollup for every hour they touch.
    func apply(_ changes: SegmentChanges, synchronously: Bool = false) {
        guard !changes.isEmpty else { return }
        let work: (Database) -> Void = { [calendar] db in
            var hours = Set<Int64>()
            db.transaction {
                for id in changes.deletedUsage {
                    db.query("SELECT start FROM usage WHERE id = ?", [.int(id)]) { row in
                        hours.insert(Self.hourStart(row.double(0), calendar))
                    }
                    db.run("DELETE FROM usage WHERE id = ?", [.int(id)])
                }
                for id in changes.deletedDetails {
                    db.run("DELETE FROM detail WHERE id = ?", [.int(id)])
                }
                for segment in changes.usage {
                    db.run("INSERT OR REPLACE INTO usage (id, start, end, app, site) VALUES (?, ?, ?, ?, ?)",
                           [.int(segment.id), .double(segment.start), .double(segment.end), .text(segment.app), .text(segment.site)])
                    hours.insert(Self.hourStart(segment.start, calendar))
                }
                for segment in changes.details {
                    db.run("INSERT OR REPLACE INTO detail (id, start, end, app, site, title, page) VALUES (?, ?, ?, ?, ?, ?, ?)",
                           [.int(segment.id), .double(segment.start), .double(segment.end), .text(segment.app),
                            .text(segment.site), .text(segment.title), .text(segment.page)])
                }
                for hour in hours {
                    Self.rebuildHour(hour, db: db, calendar: calendar)
                }
            }
        }
        if synchronously { runSync(work) } else { runAsync(work) }
    }

    static func hourStart(_ time: Double, _ calendar: Calendar) -> Int64 {
        let date = Date(timeIntervalSince1970: time)
        return Int64(calendar.dateInterval(of: .hour, for: date)?.start.timeIntervalSince1970 ?? floor(time / 3600) * 3600)
    }

    static func rebuildHour(_ bucket: Int64, db: Database, calendar: Calendar) {
        let start = Date(timeIntervalSince1970: Double(bucket))
        let end = calendar.dateInterval(of: .hour, for: start)?.end.timeIntervalSince1970 ?? Double(bucket) + 3600
        db.run("DELETE FROM hourly WHERE bucket = ?", [.int(bucket)])
        db.run("""
            INSERT INTO hourly (bucket, app, site, seconds)
            SELECT ?, app, site, SUM(end - start) FROM usage
            WHERE start >= ? AND start < ? GROUP BY app, site
            """, [.int(bucket), .double(Double(bucket)), .double(end)])
    }

    /// Rebuilds the whole rollup (after imports or bulk deletes).
    func rebuildRollup() async {
        await run { [calendar] db in
            var hours = Set<Int64>()
            db.query("SELECT start FROM usage") { hours.insert(Self.hourStart($0.double(0), calendar)) }
            db.transaction {
                db.run("DELETE FROM hourly")
                for hour in hours { Self.rebuildHour(hour, db: db, calendar: calendar) }
            }
        }
    }

    // MARK: Reading

    func hourly(_ interval: DateInterval) async -> [HourUsage] {
        await run { db in
            var rows: [HourUsage] = []
            db.query("SELECT bucket, app, site, seconds FROM hourly WHERE bucket >= ? AND bucket < ?",
                     [.int(Int64(interval.start.timeIntervalSince1970) - 1), .int(Int64(interval.end.timeIntervalSince1970))]) { row in
                rows.append(HourUsage(bucket: row.int(0), app: row.text(1), site: row.text(2), seconds: row.double(3)))
            }
            return rows
        }
    }

    /// Raw segments overlapping `interval`, clipped to it, in order.
    func segments(_ interval: DateInterval, app: String? = nil, site: String? = nil) async -> [UsageSegment] {
        await run { db in
            let start = interval.start.timeIntervalSince1970
            let end = interval.end.timeIntervalSince1970
            var sql = "SELECT id, start, end, app, site FROM usage WHERE start >= ? AND start < ?"
            var args: [Database.Value] = [.double(start - 3600), .double(end)]
            if let app { sql += " AND app = ?"; args.append(.text(app)) }
            if let site { sql += " AND site = ?"; args.append(.text(site)) }
            sql += " ORDER BY start"
            var rows: [UsageSegment] = []
            db.query(sql, args) { row in
                let segmentStart = max(row.double(1), start)
                let segmentEnd = min(row.double(2), end)
                guard segmentEnd > segmentStart else { return }
                rows.append(UsageSegment(id: row.int(0), start: segmentStart, end: segmentEnd, app: row.text(3), site: row.text(4)))
            }
            return rows
        }
    }

    func details(_ interval: DateInterval) async -> [DetailSegment] {
        await run { db in
            var rows: [DetailSegment] = []
            db.query("SELECT id, start, end, app, site, title, page FROM detail WHERE start >= ? AND start < ? ORDER BY start",
                     [.double(interval.start.timeIntervalSince1970 - 3600), .double(interval.end.timeIntervalSince1970)]) { row in
                rows.append(DetailSegment(id: row.int(0), start: row.double(1), end: row.double(2), app: row.text(3),
                                          site: row.text(4), title: row.text(5), page: row.text(6)))
            }
            return rows
        }
    }

    /// The window titles (for an app) or pages (for a site) with the most time.
    func topTitles(_ interval: DateInterval, app: String? = nil, site: String? = nil, limit: Int = 50) async -> [TitleUsage] {
        await run { db in
            var sql = "SELECT title, MAX(page), SUM(end - start) AS seconds, MAX(end) FROM detail WHERE start >= ? AND start < ?"
            var args: [Database.Value] = [.double(interval.start.timeIntervalSince1970), .double(interval.end.timeIntervalSince1970)]
            if let app { sql += " AND app = ?"; args.append(.text(app)) }
            if let site { sql += " AND site = ?"; args.append(.text(site)) }
            sql += site != nil ? " GROUP BY page, title" : " GROUP BY title"
            sql += " ORDER BY seconds DESC LIMIT \(limit)"
            var rows: [TitleUsage] = []
            db.query(sql, args) { row in
                rows.append(TitleUsage(title: row.text(0), page: row.text(1), seconds: row.double(2), lastSeen: row.double(3)))
            }
            return rows
        }
    }

    func firstActivity() async -> Date? {
        await run { db in
            var first: Double?
            db.query("SELECT MIN(start) FROM usage") { if !$0.isNull(0) { first = $0.double(0) } }
            return first.map { Date(timeIntervalSince1970: $0) }
        }
    }

    // MARK: Events

    func addEvent(_ kind: EventKind, at time: Double = Date().timeIntervalSince1970, app: String = "", site: String = "", info: String = "") {
        runAsync { db in
            db.run("INSERT INTO events (time, kind, app, site, info) VALUES (?, ?, ?, ?, ?)",
                   [.double(time), .text(kind.rawValue), .text(app), .text(site), .text(info)])
        }
    }

    func events(_ interval: DateInterval, kinds: [EventKind]? = nil) async -> [EventRecord] {
        await run { db in
            var sql = "SELECT time, kind, app, site, info FROM events WHERE time >= ? AND time < ?"
            if let kinds { sql += " AND kind IN (\(kinds.map { "'\($0.rawValue)'" }.joined(separator: ",")))" }
            sql += " ORDER BY time"
            var rows: [EventRecord] = []
            db.query(sql, [.double(interval.start.timeIntervalSince1970), .double(interval.end.timeIntervalSince1970)]) { row in
                guard let kind = EventKind(rawValue: row.text(1)) else { return }
                rows.append(EventRecord(time: row.double(0), kind: kind, app: row.text(2), site: row.text(3), info: row.text(4)))
            }
            return rows
        }
    }

    // MARK: Apps

    func saveApp(_ record: AppRecord) {
        runAsync { db in
            db.run("INSERT OR REPLACE INTO apps (id, name, path, category) VALUES (?, ?, ?, ?)",
                   [.text(record.id), .text(record.name), .text(record.path), .text(record.declaredCategory)])
        }
    }

    func apps() -> [AppRecord] {
        runSync { db in
            var rows: [AppRecord] = []
            db.query("SELECT id, name, path, category FROM apps") { row in
                rows.append(AppRecord(id: row.text(0), name: row.text(1), path: row.text(2), declaredCategory: row.text(3)))
            }
            return rows
        }
    }

    // MARK: Overrides

    func overrides() -> [String: Override] {
        runSync { db in
            var result: [String: Override] = [:]
            db.query("SELECT key, category, rating FROM overrides") { row in
                let category = row.optionalText(1).flatMap(Category.init(rawValue:))
                let rating = row.isNull(2) ? nil : Rating(rawValue: Int(row.int(2)))
                result[row.text(0)] = Override(category: category, rating: rating)
            }
            return result
        }
    }

    func setOverride(_ override: Override?, for key: String) {
        runAsync { db in
            if let override, override.category != nil || override.rating != nil {
                db.run("INSERT OR REPLACE INTO overrides (key, category, rating) VALUES (?, ?, ?)", [
                    .text(key),
                    override.category.map { .text($0.rawValue) } ?? .null,
                    override.rating.map { .int(Int64($0.rawValue)) } ?? .null,
                ])
            } else {
                db.run("DELETE FROM overrides WHERE key = ?", [.text(key)])
            }
        }
    }

    // MARK: Limits

    func limits() -> [UsageLimit] {
        runSync { db in
            var rows: [UsageLimit] = []
            db.query("SELECT id, kind, target, minutes, days, enabled FROM limits ORDER BY id") { row in
                guard let kind = UsageLimit.Kind(rawValue: row.text(1)) else { return }
                rows.append(UsageLimit(id: row.int(0), kind: kind, target: row.text(2), minutes: Int(row.int(3)),
                                       days: Int(row.int(4)), enabled: row.int(5) != 0))
            }
            return rows
        }
    }

    @discardableResult
    func saveLimit(_ limit: UsageLimit) -> Int64 {
        runSync { db in
            if limit.id > 0 {
                db.run("UPDATE limits SET kind = ?, target = ?, minutes = ?, days = ?, enabled = ? WHERE id = ?",
                       [.text(limit.kind.rawValue), .text(limit.target), .int(Int64(limit.minutes)), .int(Int64(limit.days)),
                        .int(limit.enabled ? 1 : 0), .int(limit.id)])
                return limit.id
            }
            db.run("INSERT INTO limits (kind, target, minutes, days, enabled) VALUES (?, ?, ?, ?, ?)",
                   [.text(limit.kind.rawValue), .text(limit.target), .int(Int64(limit.minutes)), .int(Int64(limit.days)),
                    .int(limit.enabled ? 1 : 0)])
            return db.lastInsertID
        }
    }

    func deleteLimit(_ id: Int64) {
        runAsync { db in db.run("DELETE FROM limits WHERE id = ?", [.int(id)]) }
    }

    // MARK: Focus

    func startFocus(start: Double, plannedEnd: Double, label: String) -> Int64 {
        runSync { db in
            db.run("INSERT INTO focus_sessions (start, planned_end, label) VALUES (?, ?, ?)",
                   [.double(start), .double(plannedEnd), .text(label)])
            return db.lastInsertID
        }
    }

    func finishFocus(id: Int64, end: Double, completed: Bool, blocked: Int) {
        runAsync { db in
            db.run("UPDATE focus_sessions SET end = ?, completed = ?, blocked = ? WHERE id = ?",
                   [.double(end), .int(completed ? 1 : 0), .int(Int64(blocked)), .int(id)])
        }
    }

    func updateFocusBlocked(id: Int64, blocked: Int) {
        runAsync { db in
            db.run("UPDATE focus_sessions SET blocked = ? WHERE id = ?", [.int(Int64(blocked)), .int(id)])
        }
    }

    func focusSessions(_ interval: DateInterval) async -> [FocusRecord] {
        await run { db in
            var rows: [FocusRecord] = []
            db.query("SELECT id, start, planned_end, end, completed, blocked, label FROM focus_sessions WHERE start >= ? AND start < ? ORDER BY start DESC",
                     [.double(interval.start.timeIntervalSince1970), .double(interval.end.timeIntervalSince1970)]) { row in
                rows.append(FocusRecord(id: row.int(0), start: row.double(1), plannedEnd: row.double(2),
                                        end: row.isNull(3) ? nil : row.double(3), completed: row.int(4) != 0,
                                        blocked: Int(row.int(5)), label: row.text(6)))
            }
            return rows
        }
    }

    /// The newest session that never ended and still has time left: a relaunch mid-session
    /// picks it back up instead of throwing it away.
    func resumableFocus(now: Double) -> FocusRecord? {
        runSync { db in
            var record: FocusRecord?
            db.query("SELECT id, start, planned_end, blocked, label FROM focus_sessions WHERE end IS NULL AND planned_end > ? ORDER BY start DESC LIMIT 1",
                     [.double(now)]) { row in
                record = FocusRecord(id: row.int(0), start: row.double(1), plannedEnd: row.double(2), end: nil, completed: false,
                                     blocked: Int(row.int(3)), label: row.text(4))
            }
            return record
        }
    }

    /// A session left open by a crash or quit: close it where it would have ended.
    func closeAbandonedFocus(now: Double, keeping kept: Int64? = nil) {
        runAsync { db in
            db.run("UPDATE focus_sessions SET end = MIN(planned_end, ?), completed = (planned_end <= ?) WHERE end IS NULL AND id != ?",
                   [.double(now), .double(now), .int(kept ?? -1)])
        }
    }

    // MARK: Maintenance

    func deleteAll() async {
        await run { db in
            try? db.exec("DELETE FROM usage; DELETE FROM detail; DELETE FROM hourly; DELETE FROM events; DELETE FROM focus_sessions;")
            try? db.exec("VACUUM")
        }
    }

    func delete(before date: Date) async {
        let cutoff = date.timeIntervalSince1970
        await run { db in
            db.transaction {
                db.run("DELETE FROM usage WHERE start < ?", [.double(cutoff)])
                db.run("DELETE FROM detail WHERE start < ?", [.double(cutoff)])
                db.run("DELETE FROM hourly WHERE bucket < ?", [.int(Int64(cutoff))])
                db.run("DELETE FROM events WHERE time < ?", [.double(cutoff)])
            }
        }
    }

    /// Window titles and pages older than `date` go; time totals stay.
    func pruneDetails(before date: Date) {
        runAsync { db in
            db.run("DELETE FROM detail WHERE start < ?", [.double(date.timeIntervalSince1970)])
        }
    }

    func fileSize() -> Int64 {
        let paths = [url.path, url.path + "-wal"]
        return paths.reduce(0) { total, path in
            total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)
        }
    }

    /// Bulk insert for demo data.
    func insertDemo(usage: [UsageSegment], details: [DetailSegment], events: [EventRecord], focus: [FocusRecord]) async {
        await run { db in
            db.transaction {
                for segment in usage {
                    db.run("INSERT INTO usage (id, start, end, app, site) VALUES (?, ?, ?, ?, ?)",
                           [.int(segment.id), .double(segment.start), .double(segment.end), .text(segment.app), .text(segment.site)])
                }
                for segment in details {
                    db.run("INSERT INTO detail (id, start, end, app, site, title, page) VALUES (?, ?, ?, ?, ?, ?, ?)",
                           [.int(segment.id), .double(segment.start), .double(segment.end), .text(segment.app), .text(segment.site),
                            .text(segment.title), .text(segment.page)])
                }
                for event in events {
                    db.run("INSERT INTO events (time, kind, app, site, info) VALUES (?, ?, ?, ?, ?)",
                           [.double(event.time), .text(event.kind.rawValue), .text(event.app), .text(event.site), .text(event.info)])
                }
                for record in focus {
                    db.run("INSERT INTO focus_sessions (start, planned_end, end, completed, blocked, label) VALUES (?, ?, ?, ?, ?, ?)",
                           [.double(record.start), .double(record.plannedEnd), record.end.map { .double($0) } ?? .null,
                            .int(record.completed ? 1 : 0), .int(Int64(record.blocked)), .text(record.label)])
                }
            }
        }
        await rebuildRollup()
    }

    var isEmpty: Bool {
        runSync { db in
            var count: Int64 = 0
            db.query("SELECT COUNT(*) FROM usage") { count = $0.int(0) }
            return count == 0
        }
    }
}
