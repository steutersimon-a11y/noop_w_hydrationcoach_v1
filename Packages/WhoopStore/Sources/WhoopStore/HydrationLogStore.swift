import Foundation
import GRDB

/// Editable drink metadata for the existing local hydration series. The total remains the
/// `metricSeries` row; cursor records hold only entry identity/time and coach acknowledgment.
public struct HydrationLogEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var amountMl: Int
    public var loggedAt: Date

    public init(id: UUID = UUID(), amountMl: Int, loggedAt: Date = Date()) {
        self.id = id
        self.amountMl = amountMl
        self.loggedAt = loggedAt
    }
}

public enum HydrationLogError: Error {
    case invalidEntry
    case storeUnavailable
}

extension WhoopStore {
    /// Lazily migrate the pre-coach entry list into the SAME SQLite transaction domain as its total.
    /// No schema is added: namespaced cursor metadata shares the database's existing backup boundary.
    public func hydrationLogEntries(day: String, legacyEntries: [HydrationLogEntry]) async throws -> [HydrationLogEntry] {
        try syncWrite { db in
            try Self.migrateHydrationEntries(day: day, legacyEntries: legacyEntries, in: db)
            return try Self.readHydrationEntries(day: day, in: db)
        }
    }

    /// Commit a drink, its editable entry and (for a reminder) its durable receipt atomically.
    /// `false` means an already acknowledged reminder or entry; callers must not buzz confirmation.
    /// A receipt is independent of the drink metadata so deleting a mistaken drink never re-arms it.
    @discardableResult
    public func addHydrationLogEntry(_ entry: HydrationLogEntry, day: String,
                                     legacyEntries: [HydrationLogEntry], reminderID: String? = nil,
                                     goalML: Int? = nil) async throws -> Bool {
        guard entry.amountMl > 0, Self.validHydrationDate(entry.loggedAt),
              !day.isEmpty, reminderID?.isEmpty != true,
              goalML.map({ $0 > 0 }) != false else { throw HydrationLogError.invalidEntry }
        return try syncWrite { db in
            try Self.migrateHydrationEntries(day: day, legacyEntries: legacyEntries, in: db)
            if let reminderID,
               try Int.fetchOne(db, sql: "SELECT value FROM cursors WHERE name = ?",
                                arguments: ["hydration:ack:" + reminderID]) != nil { return false }
            let entries = try Self.readHydrationEntries(day: day, in: db)
            guard !entries.contains(where: { $0.id == entry.id }) else { return false }
            let current = try Self.hydrationManualValue(day: day, in: db)
            if reminderID != nil, let goalML {
                // Recheck after concurrent manual/HealthKit writes within the SAME transaction.
                // User-requested manual corrections remain unconditional; coaching pauses at goal.
                let imported = try Double.fetchOne(db, sql: "SELECT value FROM metricSeries WHERE deviceId = 'hydration' AND key = 'hydrationImported' AND day = ?",
                                                    arguments: [day]) ?? 0
                guard current + imported < Double(goalML) else { return false }
            }
            try Self.writeHydrationEntry(entry, day: day, in: db)
            _ = try Self.upsertMetricSeries([MetricPoint(day: day, key: "hydration",
                                                     value: current + Double(entry.amountMl))],
                                        deviceId: "hydration", in: db)
            if let reminderID {
                try db.execute(sql: "INSERT INTO cursors (name, value) VALUES (?, ?)",
                               arguments: ["hydration:ack:" + reminderID, Int(entry.loggedAt.timeIntervalSince1970)])
            }
            return true
        }
    }

    /// Edit/delete one drink and adjust only the canonical MANUAL total in the same transaction.
    /// Imported HealthKit water is owned by its importer and never participates in this write.
    @discardableResult
    public func updateHydrationLogEntry(id: UUID, amountMl: Int, day: String,
                                        legacyEntries: [HydrationLogEntry]) async throws -> Double {
        try syncWrite { db in
            try Self.migrateHydrationEntries(day: day, legacyEntries: legacyEntries, in: db)
            let current = try Self.hydrationManualValue(day: day, in: db)
            guard let old = try Self.readHydrationEntries(day: day, in: db).first(where: { $0.id == id }) else {
                return current
            }
            try db.execute(sql: "DELETE FROM cursors WHERE name = ?",
                           arguments: [Self.hydrationEntryKey(old, day: day)])
            let amount = max(0, amountMl)
            if amount > 0 {
                try Self.writeHydrationEntry(HydrationLogEntry(id: id, amountMl: amount, loggedAt: old.loggedAt),
                                             day: day, in: db)
            }
            // Preserve older manual totals that pre-date editable entries rather than erasing them.
            let next = max(0, current - Double(old.amountMl) + Double(amount))
            _ = try Self.upsertMetricSeries([MetricPoint(day: day, key: "hydration", value: next)],
                                        deviceId: "hydration", in: db)
            return next
        }
    }

    private static func validHydrationDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && abs(seconds) < Double(Int64.max) / 1_000 - 1
    }

    private static func hydrationEntryKey(_ entry: HydrationLogEntry, day: String) -> String {
        "hydration:entry:\(day):\(entry.id.uuidString):\(Int64((entry.loggedAt.timeIntervalSince1970 * 1_000).rounded()))"
    }

    private static func writeHydrationEntry(_ entry: HydrationLogEntry, day: String, in db: Database) throws {
        try db.execute(sql: "INSERT INTO cursors (name, value) VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET value = excluded.value",
                       arguments: [hydrationEntryKey(entry, day: day), entry.amountMl])
    }

    private static func readHydrationEntries(day: String, in db: Database) throws -> [HydrationLogEntry] {
        let prefix = "hydration:entry:\(day):"
        return try Row.fetchAll(db, sql: "SELECT name, value FROM cursors WHERE substr(name, 1, ?) = ?",
                                arguments: [prefix.count, prefix]).compactMap { row in
            let name: String = row["name"]
            let amount: Int = row["value"]
            let parts = name.dropFirst(prefix.count).split(separator: ":")
            guard parts.count == 2, let id = UUID(uuidString: String(parts[0])),
                  let millis = Int64(parts[1]), amount > 0 else { return nil }
            return HydrationLogEntry(id: id, amountMl: amount,
                                     loggedAt: Date(timeIntervalSince1970: Double(millis) / 1_000))
        }.sorted { $0.loggedAt == $1.loggedAt ? $0.id.uuidString < $1.id.uuidString : $0.loggedAt < $1.loggedAt }
    }

    private static func migrateHydrationEntries(day: String, legacyEntries: [HydrationLogEntry], in db: Database) throws {
        let marker = "hydration:entries-migrated:" + day
        guard try Int.fetchOne(db, sql: "SELECT value FROM cursors WHERE name = ?", arguments: [marker]) == nil else { return }
        for entry in legacyEntries where entry.amountMl > 0 && validHydrationDate(entry.loggedAt) {
            try writeHydrationEntry(entry, day: day, in: db)
        }
        try db.execute(sql: "INSERT INTO cursors (name, value) VALUES (?, 1)", arguments: [marker])
    }

    private static func hydrationManualValue(day: String, in db: Database) throws -> Double {
        try Double.fetchOne(db, sql: "SELECT value FROM metricSeries WHERE deviceId = 'hydration' AND key = 'hydration' AND day = ?",
                            arguments: [day]) ?? 0
    }
}
