import XCTest
import GRDB
@testable import WhoopStore

final class HydrationLogStoreTests: XCTestCase {
    private let day = "2026-10-29"
    private let reminder = "hydration-coach.2026-10-29.450.Europe/Berlin"
    private let date = Date(timeIntervalSince1970: 1_793_257_200)

    private func total(_ store: WhoopStore, key: String = "hydration") async throws -> Double {
        try await store.metricSeries(deviceId: "hydration", key: key, from: day, to: day).first?.value ?? 0
    }

    func testNoTapCreatesNoDrinkOrReceipt() async throws {
        let store = try await WhoopStore.inMemory()
        let entries = try await store.hydrationLogEntries(day: day, legacyEntries: [])
        let value = try await total(store)
        let receipt = try await store.cursor("hydration:ack:" + reminder)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(value, 0)
        XCTAssertNil(receipt)
    }

    func testOneTapCommitsOneDrinkAndDuplicateDoesNotCreditAgain() async throws {
        let store = try await WhoopStore.inMemory()
        let inserted = try await store.addHydrationLogEntry(HydrationLogEntry(amountMl: 250, loggedAt: date),
                                                           day: day, legacyEntries: [], reminderID: reminder)
        let duplicate = try await store.addHydrationLogEntry(HydrationLogEntry(amountMl: 250, loggedAt: date),
                                                            day: day, legacyEntries: [], reminderID: reminder)
        let value = try await total(store)
        let entries = try await store.hydrationLogEntries(day: day, legacyEntries: [])
        XCTAssertTrue(inserted)
        XCTAssertFalse(duplicate)
        XCTAssertEqual(value, 250)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.amountMl, 250)
    }

    func testConcurrentReceiversCreditExactlyOnce() async throws {
        let store = try await WhoopStore.inMemory()
        let entry = HydrationLogEntry(amountMl: 250, loggedAt: date)
        async let first = store.addHydrationLogEntry(entry, day: day, legacyEntries: [], reminderID: reminder)
        async let second = store.addHydrationLogEntry(entry, day: day, legacyEntries: [], reminderID: reminder)
        let results = try await [first, second]
        let value = try await total(store)
        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertEqual(value, 250)
    }

    func testFailureRollsBackEntryTotalAndReceiptThenAllowsRetry() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_hydration BEFORE INSERT ON metricSeries WHEN NEW.key = 'hydration' BEGIN SELECT RAISE(ABORT, 'simulated disk failure'); END")
        }
        do {
            _ = try await store.addHydrationLogEntry(HydrationLogEntry(amountMl: 250, loggedAt: date),
                                                     day: day, legacyEntries: [], reminderID: reminder)
            XCTFail("failed commit must throw")
        } catch { }
        let receipt = try await store.cursor("hydration:ack:" + reminder)
        let entries = try await store.hydrationLogEntries(day: day, legacyEntries: [])
        let value = try await total(store)
        XCTAssertNil(receipt)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(value, 0)
        try await store.registryWriter.write { db in try db.execute(sql: "DROP TRIGGER fail_hydration") }
        let retried = try await store.addHydrationLogEntry(HydrationLogEntry(amountMl: 250, loggedAt: date),
                                                          day: day, legacyEntries: [], reminderID: reminder)
        XCTAssertTrue(retried)
    }

    func testReopenKeepsReceiptAndEditableEntryWithoutUserDefaultsMirror() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("hydration.sqlite").path
        let original = try await WhoopStore(path: path)
        _ = try await original.addHydrationLogEntry(HydrationLogEntry(amountMl: 250, loggedAt: date),
                                                    day: day, legacyEntries: [], reminderID: reminder)
        let reopened = try await WhoopStore(path: path)
        let duplicate = try await reopened.addHydrationLogEntry(HydrationLogEntry(amountMl: 250, loggedAt: date),
                                                               day: day, legacyEntries: [], reminderID: reminder)
        let entries = try await reopened.hydrationLogEntries(day: day, legacyEntries: [])
        let value = try await total(reopened)
        XCTAssertFalse(duplicate)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(value, 250)
    }

    func testReceiptFailureRollsBackTheAlreadyWrittenTotalAndEntry() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_receipt BEFORE INSERT ON cursors WHEN NEW.name LIKE 'hydration:ack:%' BEGIN SELECT RAISE(ABORT, 'receipt unavailable'); END")
        }
        do {
            _ = try await store.addHydrationLogEntry(HydrationLogEntry(amountMl: 250, loggedAt: date),
                                                     day: day, legacyEntries: [], reminderID: reminder)
            XCTFail("failed receipt must roll back the entire drink")
        } catch { }
        let value = try await total(store)
        let entries = try await store.hydrationLogEntries(day: day, legacyEntries: [])
        XCTAssertEqual(value, 0)
        XCTAssertTrue(entries.isEmpty)
    }

    func testDeleteCorrectionRetainsReceiptAndImportedWater() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([MetricPoint(day: day, key: "hydrationImported", value: 400)], deviceId: "hydration")
        let entry = HydrationLogEntry(amountMl: 250, loggedAt: date)
        _ = try await store.addHydrationLogEntry(entry, day: day, legacyEntries: [], reminderID: reminder)
        let corrected = try await store.updateHydrationLogEntry(id: entry.id, amountMl: 125, day: day, legacyEntries: [])
        XCTAssertEqual(corrected, 125)
        let deleted = try await store.updateHydrationLogEntry(id: entry.id, amountMl: 0, day: day, legacyEntries: [])
        XCTAssertEqual(deleted, 0)
        let duplicate = try await store.addHydrationLogEntry(entry, day: day, legacyEntries: [], reminderID: reminder)
        let imported = try await total(store, key: "hydrationImported")
        let entries = try await store.hydrationLogEntries(day: day, legacyEntries: [])
        XCTAssertFalse(duplicate)
        XCTAssertEqual(imported, 400)
        XCTAssertTrue(entries.isEmpty)
    }

    func testMigrationIsOneTimeAndPreservesExistingManualTotal() async throws {
        let store = try await WhoopStore.inMemory()
        let old = HydrationLogEntry(amountMl: 500, loggedAt: date)
        try await store.upsertMetricSeries([MetricPoint(day: day, key: "hydration", value: 650)], deviceId: "hydration")
        let migrated = try await store.hydrationLogEntries(day: day, legacyEntries: [old])
        XCTAssertEqual(migrated, [old])
        _ = try await store.updateHydrationLogEntry(id: old.id, amountMl: 250, day: day, legacyEntries: [old])
        let reread = try await store.hydrationLogEntries(day: day, legacyEntries: [old])
        let value = try await total(store)
        XCTAssertEqual(reread.first?.amountMl, 250, "stale compatibility mirror must not overwrite DB edits")
        XCTAssertEqual(value, 400, "150 ml predating editable entries must be preserved")
    }

    func testConcurrentManualAndCoachDrinkBothAccumulate() async throws {
        let store = try await WhoopStore.inMemory()
        async let manual = store.addHydrationLogEntry(HydrationLogEntry(amountMl: 500, loggedAt: date), day: day, legacyEntries: [])
        async let coach = store.addHydrationLogEntry(HydrationLogEntry(amountMl: 250, loggedAt: date), day: day,
                                                    legacyEntries: [], reminderID: reminder)
        _ = try await (manual, coach)
        let value = try await total(store)
        let entries = try await store.hydrationLogEntries(day: day, legacyEntries: [])
        XCTAssertEqual(value, 750)
        XCTAssertEqual(entries.count, 2)
    }

    func testInvalidServingNeverCreatesReceipt() async throws {
        let store = try await WhoopStore.inMemory()
        for amount in [0, -250] {
            do {
                _ = try await store.addHydrationLogEntry(HydrationLogEntry(amountMl: amount, loggedAt: date),
                                                         day: day, legacyEntries: [], reminderID: reminder)
                XCTFail("invalid amount must throw")
            } catch { }
        }
        let receipt = try await store.cursor("hydration:ack:" + reminder)
        XCTAssertNil(receipt)
    }

    func testGoalReachedByManualOrHealthImportBeforeCommitSuppressesCoachOnly() async throws {
        for key in ["hydration", "hydrationImported"] {
            let store = try await WhoopStore.inMemory()
            try await store.upsertMetricSeries([MetricPoint(day: day, key: key, value: 3_000)], deviceId: "hydration")
            let inserted = try await store.addHydrationLogEntry(HydrationLogEntry(amountMl: 250, loggedAt: date),
                day: day, legacyEntries: [], reminderID: reminder, goalML: 3_000)
            XCTAssertFalse(inserted)
            let receipt = try await store.cursor("hydration:ack:" + reminder)
            XCTAssertNil(receipt)
            let entries = try await store.hydrationLogEntries(day: day, legacyEntries: [])
            XCTAssertTrue(entries.isEmpty)
            let manual = try await store.addHydrationLogEntry(HydrationLogEntry(amountMl: 250, loggedAt: date),
                day: day, legacyEntries: [])
            XCTAssertTrue(manual, "the personal goal must not prevent an explicit manual log")
        }
    }

    func testInvalidDateCannotOverflowPersistentTimestamp() async throws {
        let store = try await WhoopStore.inMemory()
        for seconds in [Double.infinity, -Double.infinity, 1e20, -1e20] {
            do {
                _ = try await store.addHydrationLogEntry(
                    HydrationLogEntry(amountMl: 250, loggedAt: Date(timeIntervalSince1970: seconds)),
                    day: day, legacyEntries: [], reminderID: reminder)
                XCTFail("unrepresentable timestamp must throw")
            } catch { }
        }
        let value = try await total(store)
        XCTAssertEqual(value, 0)
    }
}
