import Foundation
import SQLite3

/// Long-horizon telemetry storage.
///
/// The dish only keeps 12 hours of history in its own ring buffer, and loses it
/// on every reboot. Cathode records what it sees so the app can answer questions
/// the dish cannot: what did last month look like, when did the outages cluster,
/// is the obstruction getting worse since the tree was trimmed.
///
/// Two resolutions, so the database stays small without losing the long view:
///  * `samples` — one row per second, kept for 48 hours. Fine detail for charts.
///  * `rollups` — one row per minute, kept forever. ~525k rows per year, which
///    is a few tens of MB and queries instantly.
///
/// Uses the system SQLite directly; no dependencies, and no ORM between the app
/// and queries that need to aggregate hundreds of thousands of rows.
actor HistoryStore {
    /// `nonisolated(unsafe)` so `deinit` can close the handle. Safe because the
    /// pointer is only ever mutated during `init`, and `deinit` runs when no
    /// other reference to the actor remains.
    private nonisolated(unsafe) var db: OpaquePointer?
    private let url: URL
    /// Buffered seconds awaiting a rollup flush.
    private var pending: [HistorySample] = []

    static let rawRetention: TimeInterval = 48 * 3600

    /// Opens the database and applies the schema. Migration runs here rather
    /// than in `init` because a synchronous actor initialiser cannot call
    /// isolated methods under Swift 6 strict concurrency.
    static func open(filename: String = "cathode.sqlite3",
                     inMemory: Bool = false) async throws -> HistoryStore {
        let store = try HistoryStore(filename: filename, inMemory: inMemory)
        try await store.migrate()
        return store
    }

    private init(filename: String, inMemory: Bool) throws {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        self.url = inMemory ? URL(fileURLWithPath: ":memory:") : directory.appending(path: filename)

        var handle: OpaquePointer?
        let path = inMemory ? ":memory:" : url.path(percentEncoded: false)
        guard sqlite3_open_v2(path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let handle else {
            throw StoreError("Could not open the telemetry database at \(path).")
        }
        self.db = handle
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    struct StoreError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - Schema

    func migrate() throws {
        // WAL keeps writes from blocking the chart queries that run on every
        // range change; NORMAL sync is right for telemetry we can afford to
        // lose a second of after a hard crash.
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("""
            CREATE TABLE IF NOT EXISTS samples (
                t        INTEGER PRIMARY KEY,
                down     REAL NOT NULL,
                up       REAL NOT NULL,
                latency  REAL,
                drop_    REAL NOT NULL,
                power    REAL,
                flags    INTEGER NOT NULL DEFAULT 0
            );
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS rollups (
                t            INTEGER PRIMARY KEY,
                down_avg     REAL NOT NULL,
                down_max     REAL NOT NULL,
                up_avg       REAL NOT NULL,
                up_max       REAL NOT NULL,
                lat_avg      REAL,
                lat_max      REAL,
                lat_p95      REAL,
                drop_avg     REAL NOT NULL,
                power_avg    REAL,
                bytes_down   REAL NOT NULL DEFAULT 0,
                bytes_up     REAL NOT NULL DEFAULT 0,
                obstructed_s INTEGER NOT NULL DEFAULT 0,
                outage_s     INTEGER NOT NULL DEFAULT 0,
                samples      INTEGER NOT NULL
            );
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS outages (
                start_t  INTEGER PRIMARY KEY,
                end_t    INTEGER NOT NULL,
                cause    TEXT NOT NULL
            );
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS speedtests (
                t             INTEGER PRIMARY KEY,
                down          REAL NOT NULL,
                up            REAL NOT NULL,
                latency       REAL NOT NULL,
                load_down     REAL,
                load_up       REAL
            );
            """)
        try exec("CREATE INDEX IF NOT EXISTS idx_outages_end ON outages(end_t);")
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(error)
            throw StoreError(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    // MARK: - Ingest

    /// Flag bits packed into `samples.flags`.
    private enum Flag {
        static let obstructed = 1
        static let noSchedule = 2
    }

    /// Records new seconds. Duplicate timestamps are ignored, so overlapping
    /// reads of the dish's ring buffer are safe to hand straight in — and the
    /// poll loop deliberately overlaps, re-reading the tail of the ring every
    /// thirty seconds to catch anything a missed poll would have dropped.
    ///
    /// Only rows that were genuinely inserted are queued for rollup. Counting
    /// the ignored duplicates too would inflate every byte total and sample
    /// count downstream, in proportion to how often the tail is re-read.
    func ingest(_ samples: [HistorySample]) throws {
        guard !samples.isEmpty else { return }
        var inserted: [HistorySample] = []
        inserted.reserveCapacity(samples.count)
        try exec("BEGIN IMMEDIATE;")
        do {
            let statement = try prepare("""
                INSERT OR IGNORE INTO samples (t, down, up, latency, drop_, power, flags)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """)
            defer { sqlite3_finalize(statement) }
            for s in samples {
                sqlite3_bind_int64(statement, 1, Int64(s.t.timeIntervalSince1970.rounded()))
                sqlite3_bind_double(statement, 2, s.downlinkBps)
                sqlite3_bind_double(statement, 3, s.uplinkBps)
                if let latency = s.latencyMs { sqlite3_bind_double(statement, 4, latency) }
                else { sqlite3_bind_null(statement, 4) }
                sqlite3_bind_double(statement, 5, s.dropRate)
                if let power = s.powerW { sqlite3_bind_double(statement, 6, power) }
                else { sqlite3_bind_null(statement, 6) }
                var flags = 0
                if s.obstructed { flags |= Flag.obstructed }
                if s.noSchedule { flags |= Flag.noSchedule }
                sqlite3_bind_int(statement, 7, Int32(flags))
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw StoreError(String(cString: sqlite3_errmsg(db)))
                }
                // INSERT OR IGNORE reports zero changes when the second was
                // already recorded.
                if sqlite3_changes(db) > 0 { inserted.append(s) }
                sqlite3_reset(statement)
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        pending.append(contentsOf: inserted)
    }

    func record(_ result: SpeedTestResult) throws {
        let statement = try prepare("""
            INSERT OR REPLACE INTO speedtests (t, down, up, latency, load_down, load_up)
            VALUES (?, ?, ?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(result.timestamp.timeIntervalSince1970))
        sqlite3_bind_double(statement, 2, result.downlinkBps)
        sqlite3_bind_double(statement, 3, result.uplinkBps)
        sqlite3_bind_double(statement, 4, result.latencyMs)
        if let d = result.latencyUnderLoadDownMs { sqlite3_bind_double(statement, 5, d) }
        else { sqlite3_bind_null(statement, 5) }
        if let u = result.latencyUnderLoadUpMs { sqlite3_bind_double(statement, 6, u) }
        else { sqlite3_bind_null(statement, 6) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError(String(cString: sqlite3_errmsg(db)))
        }
    }

    func record(outage: OutageRecord) throws {
        let statement = try prepare(
            "INSERT OR REPLACE INTO outages (start_t, end_t, cause) VALUES (?, ?, ?);")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(outage.start.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(outage.end.timeIntervalSince1970))
        sqlite3_bind_text(statement, 3, outage.cause, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Folds buffered seconds into minute rollups and trims raw history.
    /// Called periodically; safe to call when nothing is pending.
    func compact(now: Date = .now) throws {
        try rollUpPending()
        let cutoff = Int64((now - Self.rawRetention).timeIntervalSince1970)
        let statement = try prepare("DELETE FROM samples WHERE t < ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, cutoff)
        _ = sqlite3_step(statement)
    }

    private func rollUpPending() throws {
        guard !pending.isEmpty else { return }
        // Group by minute, holding back whichever minute is still filling. That
        // boundary comes from the newest sample rather than the wall clock, so
        // back-filled history rolls up correctly instead of waiting for a clock
        // that has already moved past it.
        let newest = pending.map(\.t).max() ?? Date()
        let currentMinute = Int(max(newest, Date()).timeIntervalSince1970) / 60
        var buckets: [Int: [HistorySample]] = [:]
        var carry: [HistorySample] = []
        for sample in pending {
            let minute = Int(sample.t.timeIntervalSince1970) / 60
            if minute >= currentMinute { carry.append(sample) }
            else { buckets[minute, default: []].append(sample) }
        }
        pending = carry
        guard !buckets.isEmpty else { return }

        try exec("BEGIN IMMEDIATE;")
        do {
            let statement = try prepare("""
                INSERT OR REPLACE INTO rollups
                (t, down_avg, down_max, up_avg, up_max, lat_avg, lat_max, lat_p95,
                 drop_avg, power_avg, bytes_down, bytes_up, obstructed_s, outage_s, samples)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """)
            defer { sqlite3_finalize(statement) }

            for (minute, group) in buckets {
                let downs = group.map(\.downlinkBps)
                let ups = group.map(\.uplinkBps)
                let latencies = group.compactMap(\.latencyMs).sorted()
                let powers = group.compactMap(\.powerW)

                sqlite3_bind_int64(statement, 1, Int64(minute * 60))
                sqlite3_bind_double(statement, 2, downs.mean)
                sqlite3_bind_double(statement, 3, downs.max() ?? 0)
                sqlite3_bind_double(statement, 4, ups.mean)
                sqlite3_bind_double(statement, 5, ups.max() ?? 0)
                if latencies.isEmpty {
                    sqlite3_bind_null(statement, 6)
                    sqlite3_bind_null(statement, 7)
                    sqlite3_bind_null(statement, 8)
                } else {
                    sqlite3_bind_double(statement, 6, latencies.mean)
                    sqlite3_bind_double(statement, 7, latencies.last ?? 0)
                    sqlite3_bind_double(statement, 8, latencies.percentile(0.95))
                }
                sqlite3_bind_double(statement, 9, group.map(\.dropRate).mean)
                if powers.isEmpty { sqlite3_bind_null(statement, 10) }
                else { sqlite3_bind_double(statement, 10, powers.mean) }
                // Each sample covers one second, so bps sums to bits, /8 to bytes.
                sqlite3_bind_double(statement, 11, downs.reduce(0, +) / 8)
                sqlite3_bind_double(statement, 12, ups.reduce(0, +) / 8)
                sqlite3_bind_int(statement, 13, Int32(group.count(where: { $0.obstructed })))
                sqlite3_bind_int(statement, 14, Int32(group.count(where: { $0.isOutage })))
                sqlite3_bind_int(statement, 15, Int32(group.count))

                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw StoreError(String(cString: sqlite3_errmsg(db)))
                }
                sqlite3_reset(statement)
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Queries

    /// Reads a time range at whichever resolution keeps the result under
    /// `maxPoints`, so a one-month chart costs the same as a one-hour chart.
    func series(from: Date, to: Date, maxPoints: Int = 600) throws -> [Aggregate] {
        let span = to.timeIntervalSince(from)
        let useRaw = span <= 6 * 3600 && from > .now - Self.rawRetention
        // Bucket width in seconds, rounded up to a whole unit of the source table.
        let unit: Double = useRaw ? 1 : 60
        let bucket = max(unit, (span / Double(maxPoints) / unit).rounded(.up) * unit)

        let sql = useRaw ? """
            SELECT (t / ?) * ? AS bucket,
                   AVG(down), MAX(down), AVG(up), MAX(up),
                   AVG(latency), MAX(latency), AVG(drop_), AVG(power),
                   SUM(CASE WHEN flags & 1 THEN 1 ELSE 0 END),
                   SUM(CASE WHEN drop_ >= 1 THEN 1 ELSE 0 END),
                   COUNT(*)
            FROM samples WHERE t >= ? AND t <= ? GROUP BY bucket ORDER BY bucket;
            """ : """
            SELECT (t / ?) * ? AS bucket,
                   AVG(down_avg), MAX(down_max), AVG(up_avg), MAX(up_max),
                   AVG(lat_avg), MAX(lat_max), AVG(drop_avg), AVG(power_avg),
                   SUM(obstructed_s), SUM(outage_s), SUM(samples)
            FROM rollups WHERE t >= ? AND t <= ? GROUP BY bucket ORDER BY bucket;
            """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(bucket))
        sqlite3_bind_int64(statement, 2, Int64(bucket))
        sqlite3_bind_int64(statement, 3, Int64(from.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 4, Int64(to.timeIntervalSince1970))

        var out: [Aggregate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append(Aggregate(
                t: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0))),
                downAvg: sqlite3_column_double(statement, 1),
                downMax: sqlite3_column_double(statement, 2),
                upAvg: sqlite3_column_double(statement, 3),
                upMax: sqlite3_column_double(statement, 4),
                latencyAvg: nullableDouble(statement, 5),
                latencyMax: nullableDouble(statement, 6),
                dropAvg: sqlite3_column_double(statement, 7),
                powerAvg: nullableDouble(statement, 8),
                obstructedSeconds: Int(sqlite3_column_int64(statement, 9)),
                outageSeconds: Int(sqlite3_column_int64(statement, 10)),
                sampleCount: Int(sqlite3_column_int64(statement, 11))))
        }
        return out
    }

    /// Total bytes moved in a window, for the data-usage screen.
    func usage(from: Date, to: Date) throws -> (down: Double, up: Double) {
        let statement = try prepare(
            "SELECT SUM(bytes_down), SUM(bytes_up) FROM rollups WHERE t >= ? AND t <= ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(from.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(to.timeIntervalSince1970))
        guard sqlite3_step(statement) == SQLITE_ROW else { return (0, 0) }
        return (sqlite3_column_double(statement, 0), sqlite3_column_double(statement, 1))
    }

    /// Uptime for a window: the share of recorded seconds that were not outages.
    func uptime(from: Date, to: Date) throws -> UptimeSummary {
        let statement = try prepare("""
            SELECT SUM(samples), SUM(outage_s), SUM(obstructed_s)
            FROM rollups WHERE t >= ? AND t <= ?;
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(from.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(to.timeIntervalSince1970))
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return UptimeSummary(recordedSeconds: 0, outageSeconds: 0, obstructedSeconds: 0)
        }
        return UptimeSummary(
            recordedSeconds: Int(sqlite3_column_int64(statement, 0)),
            outageSeconds: Int(sqlite3_column_int64(statement, 1)),
            obstructedSeconds: Int(sqlite3_column_int64(statement, 2)))
    }

    func outages(from: Date, to: Date, limit: Int = 200) throws -> [OutageRecord] {
        let statement = try prepare("""
            SELECT start_t, end_t, cause FROM outages
            WHERE end_t >= ? AND start_t <= ? ORDER BY start_t DESC LIMIT ?;
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(from.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(to.timeIntervalSince1970))
        sqlite3_bind_int(statement, 3, Int32(limit))

        var out: [OutageRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append(OutageRecord(
                start: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0))),
                end: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 1))),
                cause: String(cString: sqlite3_column_text(statement, 2))))
        }
        return out
    }

    func speedTests(limit: Int = 60) throws -> [SpeedTestResult] {
        let statement = try prepare("""
            SELECT t, down, up, latency, load_down, load_up
            FROM speedtests ORDER BY t DESC LIMIT ?;
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var out: [SpeedTestResult] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append(SpeedTestResult(
                timestamp: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0))),
                downlinkBps: sqlite3_column_double(statement, 1),
                uplinkBps: sqlite3_column_double(statement, 2),
                latencyMs: sqlite3_column_double(statement, 3),
                latencyUnderLoadDownMs: nullableDouble(statement, 4),
                latencyUnderLoadUpMs: nullableDouble(statement, 5)))
        }
        return out
    }

    /// Newest recorded second, so a reconnect knows where to resume from.
    func latestSampleTime() throws -> Date? {
        let statement = try prepare("SELECT MAX(t) FROM samples;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0)))
    }

    func statistics() throws -> StoreStatistics {
        func count(_ table: String) throws -> Int {
            let statement = try prepare("SELECT COUNT(*) FROM \(table);")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
        let attributes = try? FileManager.default
            .attributesOfItem(atPath: url.path(percentEncoded: false))
        let size = (attributes?[.size] as? Int) ?? 0
        let statement = try prepare("SELECT MIN(t) FROM rollups;")
        defer { sqlite3_finalize(statement) }
        var oldest: Date?
        if sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL {
            oldest = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0)))
        }
        return StoreStatistics(
            sampleRows: try count("samples"),
            rollupRows: try count("rollups"),
            outageRows: try count("outages"),
            speedTestRows: try count("speedtests"),
            oldestRecord: oldest,
            fileSizeBytes: size)
    }

    func eraseAll() throws {
        for table in ["samples", "rollups", "outages", "speedtests"] {
            try exec("DELETE FROM \(table);")
        }
        pending.removeAll()
        try exec("VACUUM;")
    }

    private func nullableDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL
            ? nil : sqlite3_column_double(statement, index)
    }
}

/// One bucket of aggregated telemetry.
struct Aggregate: Sendable, Identifiable, Equatable {
    var t: Date
    var downAvg: Double
    var downMax: Double
    var upAvg: Double
    var upMax: Double
    var latencyAvg: Double?
    var latencyMax: Double?
    var dropAvg: Double
    var powerAvg: Double?
    var obstructedSeconds: Int
    var outageSeconds: Int
    var sampleCount: Int

    var id: Date { t }
    /// True when the bucket is entirely down — drawn as a gap, not a zero.
    var isFullOutage: Bool { sampleCount > 0 && outageSeconds >= sampleCount }
}

struct OutageRecord: Sendable, Identifiable, Equatable {
    var start: Date
    var end: Date
    var cause: String
    var id: Date { start }
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct UptimeSummary: Sendable, Equatable {
    var recordedSeconds: Int
    var outageSeconds: Int
    var obstructedSeconds: Int

    /// Availability as a fraction. Nil when nothing has been recorded yet, so
    /// the UI can say "no data" instead of claiming a perfect 100%.
    var availability: Double? {
        guard recordedSeconds > 0 else { return nil }
        return Double(recordedSeconds - outageSeconds) / Double(recordedSeconds)
    }

    /// The "number of nines" phrasing operators actually use.
    var ninesLabel: String {
        guard let availability, availability < 1 else { return "100%" }
        return Format.decimal(availability * 100, places: availability > 0.999 ? 3 : 2) + "%"
    }
}

struct StoreStatistics: Sendable, Equatable {
    var sampleRows: Int
    var rollupRows: Int
    var outageRows: Int
    var speedTestRows: Int
    var oldestRecord: Date?
    var fileSizeBytes: Int
}

extension Collection where Element == Double {
    var mean: Double { isEmpty ? 0 : reduce(0, +) / Double(count) }
}

extension Array where Element == Double {
    /// Assumes the array is already sorted ascending.
    func percentile(_ p: Double) -> Double {
        guard !isEmpty else { return 0 }
        let index = Int((Double(count - 1) * p).rounded())
        return self[Swift.max(0, Swift.min(count - 1, index))]
    }
}
