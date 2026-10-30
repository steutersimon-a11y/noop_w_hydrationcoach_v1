import XCTest
@testable import HydrationCoach

final class HydrationCoachTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return value
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private let settings = HydrationCoachSettings(enabled: true, endMinute: 1_290, intervalMinutes: 75)
    private var morning: Date { date("2026-10-29T07:30:00+01:00") }

    private func opened() -> (HydrationCoachSession, HydrationCoachReminder) {
        var session = HydrationCoachSession(now: morning.addingTimeInterval(-1))
        let reminder = session.candidate(at: morning, settings: settings, totalML: 0,
                                         workoutActive: false, calendar: calendar)!
        XCTAssertTrue(session.open(reminder, at: morning, settings: settings,
                                   didAttemptHaptic: true, totalML: 0,
                                   workoutActive: false, calendar: calendar))
        return (session, reminder)
    }

    private func tap(_ session: inout HydrationCoachSession, at now: Date,
                     event: Date? = nil, total: Double = 0, workout: Bool = false,
                     connected: Bool = true) -> HydrationCoachTapDecision {
        session.prepareTap(eventDate: event ?? now, receivedAt: now, settings: settings,
                           totalML: total, workoutActive: workout,
                           connected: connected, calendar: calendar)
    }

    func testDefaultsAreExplicitlyOptInAndRoundTrip() throws {
        let defaults = HydrationCoachSettings()
        XCTAssertFalse(defaults.enabled)
        XCTAssertEqual(defaults.personalGoalML, 3_000)
        XCTAssertEqual(defaults.servingML, 250)
        XCTAssertEqual(defaults.startMinute, 450)
        XCTAssertEqual(defaults.bottleML, 500)
        XCTAssertEqual(defaults.endMinute, 1_410)
        XCTAssertEqual(defaults.intervalMinutes, 60)
        XCTAssertTrue(defaults.isValid)
        XCTAssertEqual(try JSONDecoder().decode(HydrationCoachSettings.self,
                       from: JSONEncoder().encode(defaults)), defaults)
        XCTAssertTrue(HydrationCoachSchedule.reminders(on: morning, settings: defaults,
                                                       calendar: calendar).isEmpty)
    }

    func testDefaultCadenceHonorsWakingWindow() {
        let reminders = HydrationCoachSchedule.reminders(on: morning, settings: settings, calendar: calendar)
        XCTAssertEqual(reminders.count, 12)
        XCTAssertEqual(reminders.first?.scheduledAt, morning)
        XCTAssertEqual(reminders.last?.scheduledAt, date("2026-10-29T21:15:00+01:00"))
        for (i, reminder) in reminders.enumerated() {
            XCTAssertEqual(calendar.component(.hour, from: reminder.scheduledAt) * 60 +
                           calendar.component(.minute, from: reminder.scheduledAt), 450 + 75 * i)
            XCTAssertEqual(reminder.expiresAt.timeIntervalSince(reminder.scheduledAt), 120)
        }
        XCTAssertEqual(Set(reminders.map(\.id)).count, reminders.count)
    }

    func testMalformedPreferencesNeverSchedule() {
        var variants: [HydrationCoachSettings] = []
        for value in [0, -1, 14, 241, Int.max] {
            var s = settings; s.intervalMinutes = value; variants.append(s)
        }
        for value in [-1, 1_440, Int.max] {
            var s = settings; s.endMinute = value; variants.append(s)
        }
        var s = settings; s.personalGoalML = Int.max; variants.append(s)
        s = settings; s.servingML = 0; variants.append(s)
        for variant in variants {
            XCTAssertFalse(variant.isValid)
            XCTAssertTrue(HydrationCoachSchedule.reminders(on: morning, settings: variant,
                                                          calendar: calendar).isEmpty)
        }
        for pair in [(450, 450), (500, 400), (-1, 500)] {
            var s = settings; s.startMinute = pair.0; s.endMinute = pair.1
            XCTAssertTrue(HydrationCoachSchedule.reminders(on: morning, settings: s,
                                                          calendar: calendar).isEmpty)
        }
    }

    func testWindowNeverExtendsPastWakingEnd() {
        var s = settings; s.endMinute = 451
        let reminders = HydrationCoachSchedule.reminders(on: morning, settings: s, calendar: calendar)
        XCTAssertEqual(reminders.count, 1)
        XCTAssertEqual(reminders[0].expiresAt, morning.addingTimeInterval(60))
    }

    func testGoalCancelsTodayNotificationsButRetainsTomorrow() {
        let now = morning.addingTimeInterval(1)
        let reminders = HydrationCoachSchedule.notificationReminders(at: now, settings: settings,
            totalML: 3_000, workoutActive: false, calendar: calendar)
        XCTAssertFalse(reminders.isEmpty)
        XCTAssertTrue(reminders.allSatisfy { $0.dayKey == "2026-10-30" })
        XCTAssertTrue(HydrationCoachSchedule.notificationReminders(at: now, settings: settings,
            totalML: 0, workoutActive: true, calendar: calendar).isEmpty)
    }

    func testNotificationsAreStrictlyFutureBoundedAndDefaultCovers24Hours() {
        var s = settings; s.startMinute = 0; s.endMinute = 1_439; s.intervalMinutes = 15
        let reminders = HydrationCoachSchedule.notificationReminders(at: morning, settings: s,
            totalML: 0, workoutActive: false, calendar: calendar, limit: Int.max)
        XCTAssertEqual(reminders.count, 32)
        XCTAssertTrue(reminders.allSatisfy {
            $0.scheduledAt > morning && $0.scheduledAt <= morning.addingTimeInterval(86_400)
        })
        XCTAssertTrue(HydrationCoachSchedule.notificationReminders(at: morning, settings: settings,
            totalML: 0, workoutActive: false, calendar: calendar, limit: -1).isEmpty)
        let defaults = HydrationCoachSchedule.notificationReminders(at: morning, settings: settings,
            totalML: 0, workoutActive: false, calendar: calendar)
        XCTAssertEqual(defaults.count, 12)
    }

    func testNoTapCreditsZero() {
        var (session, reminder) = opened()
        var persistedML = 0
        if case .log = tap(&session, at: reminder.expiresAt) { persistedML += settings.servingML }
        XCTAssertEqual(persistedML, 0)
        XCTAssertFalse(session.isCommitting)
    }

    func testOneTapReservesOneServingAndReplayCannotReserveAgain() {
        var (session, reminder) = opened()
        let now = morning.addingTimeInterval(10)
        var persistedML = 0
        if case .log(let accepted) = tap(&session, at: now) {
            XCTAssertEqual(accepted.id, reminder.id)
            persistedML += settings.servingML
        } else { XCTFail("Expected a log reservation") }
        XCTAssertTrue(session.isCommitting)
        XCTAssertEqual(tap(&session, at: now), .duplicate)
        session.finish(reminderID: reminder.id, committed: true)
        XCTAssertEqual(tap(&session, at: now.addingTimeInterval(20), event: now), .duplicate)
        XCTAssertNil(session.candidate(at: now, settings: settings, totalML: 250,
                                       workoutActive: false, calendar: calendar))
        XCTAssertEqual(persistedML, 250)
    }

    func testFailedPersistenceClosesWindowWithoutConfirmationOrRetry() {
        var (session, reminder) = opened()
        XCTAssertEqual(tap(&session, at: morning.addingTimeInterval(1)), .log(reminder))
        session.finish(reminderID: reminder.id, committed: false)
        XCTAssertFalse(session.isCommitting)
        XCTAssertNil(session.activeReminder)
        XCTAssertEqual(tap(&session, at: morning.addingTimeInterval(5)), .duplicate)
        XCTAssertEqual(tap(&session, at: morning.addingTimeInterval(120)), .ignored)
    }

    func testUnsentHapticDoesNotOpenWindow() {
        var session = HydrationCoachSession(now: morning.addingTimeInterval(-1))
        let reminder = session.candidate(at: morning, settings: settings, totalML: 0,
                                         workoutActive: false, calendar: calendar)!
        XCTAssertFalse(session.open(reminder, at: morning, settings: settings,
                                    didAttemptHaptic: false, totalML: 0,
                                    workoutActive: false, calendar: calendar))
        XCTAssertEqual(tap(&session, at: morning.addingTimeInterval(1)), .ignored)
    }

    func testOldFutureMissingAndExpiredEventTimestampsFailClosed() {
        var (session, _) = opened()
        let now = morning.addingTimeInterval(10)
        XCTAssertEqual(tap(&session, at: now, event: morning.addingTimeInterval(-1)), .ignored)
        XCTAssertEqual(tap(&session, at: now, event: now.addingTimeInterval(1)), .ignored)
        XCTAssertEqual(session.prepareTap(eventDate: nil, receivedAt: now, settings: settings,
                                          totalML: 0, workoutActive: false, connected: true,
                                          calendar: calendar), .ignored)
        XCTAssertEqual(tap(&session, at: morning.addingTimeInterval(120)), .ignored)
    }

    func testTapBeforeActualHapticAttemptCannotConfirm() {
        var session = HydrationCoachSession(now: morning.addingTimeInterval(-1))
        let later = morning.addingTimeInterval(30)
        let reminder = session.candidate(at: later, settings: settings, totalML: 0,
                                         workoutActive: false, calendar: calendar)!
        XCTAssertTrue(session.open(reminder, at: later, settings: settings, didAttemptHaptic: true,
                                   totalML: 0, workoutActive: false, calendar: calendar))
        XCTAssertEqual(tap(&session, at: later.addingTimeInterval(10), event: morning), .ignored)
    }

    func testDisconnectAndReconnectNeverRestoreCurrentReminder() {
        var (session, _) = opened()
        let now = morning.addingTimeInterval(5)
        XCTAssertEqual(tap(&session, at: now, connected: false), .ignored)
        session.invalidate(at: now)
        XCTAssertNil(session.candidate(at: now.addingTimeInterval(10), settings: settings,
                                       totalML: 0, workoutActive: false, calendar: calendar))
        XCTAssertEqual(tap(&session, at: now.addingTimeInterval(10)), .ignored)
        let next = morning.addingTimeInterval(75 * 60)
        XCTAssertNotNil(session.candidate(at: next, settings: settings, totalML: 0,
                                          workoutActive: false, calendar: calendar))
    }

    func testReopenDoesNotInferNotificationOrTapFromElapsedSlot() {
        var reopened = HydrationCoachSession(now: morning.addingTimeInterval(10))
        XCTAssertNil(reopened.candidate(at: morning.addingTimeInterval(20), settings: settings,
                                        totalML: 0, workoutActive: false, calendar: calendar))
        XCTAssertEqual(tap(&reopened, at: morning.addingTimeInterval(30)), .ignored)
    }

    func testWorkoutsAndGoalCompletionSuppressBothCueAndCredit() {
        var (session, _) = opened()
        XCTAssertEqual(tap(&session, at: morning.addingTimeInterval(1), workout: true), .ignored)
        XCTAssertNil(session.candidate(at: morning, settings: settings, totalML: 0,
                                       workoutActive: true, calendar: calendar))
        (session, _) = opened()
        XCTAssertEqual(tap(&session, at: morning.addingTimeInterval(1), total: 3_000), .ignored)
        for total in [3_000.0, 5_000, .nan, .infinity, -1] {
            XCTAssertNil(session.candidate(at: morning, settings: settings, totalML: total,
                                           workoutActive: false, calendar: calendar))
        }
    }

    func testSettingsChangeAndDifferentLocalDayCannotConfirmOldWindow() {
        var (session, _) = opened()
        var changed = settings; changed.servingML = 500
        XCTAssertEqual(session.prepareTap(eventDate: morning, receivedAt: morning,
                                          settings: changed, totalML: 0, workoutActive: false,
                                          connected: true, calendar: calendar), .ignored)
        XCTAssertEqual(tap(&session, at: date("2026-10-30T07:30:00+01:00"), event: morning), .ignored)
        var otherZone = calendar; otherZone.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(session.prepareTap(eventDate: morning, receivedAt: morning, settings: settings,
                                          totalML: 0, workoutActive: false, connected: true,
                                          calendar: otherZone), .ignored)
    }

    func testDSTSpringSkipsNonexistentSlotAndFallOccursOnce() {
        var s = settings; s.startMinute = 90; s.endMinute = 270; s.intervalMinutes = 60
        let spring = HydrationCoachSchedule.reminders(on: date("2026-03-29T00:00:00+01:00"),
                                                       settings: s, calendar: calendar)
        XCTAssertEqual(spring.map { calendar.component(.hour, from: $0.scheduledAt) }, [1, 3])
        let fall = HydrationCoachSchedule.reminders(on: date("2026-10-25T00:00:00+02:00"),
                                                     settings: s, calendar: calendar)
        XCTAssertEqual(fall.map { calendar.component(.hour, from: $0.scheduledAt) }, [1, 2, 3])
        XCTAssertEqual(Set(fall.map(\.id)).count, 3)
        XCTAssertEqual(fall[1].scheduledAt, date("2026-10-25T02:30:00+02:00"))
    }

    func testMissingSpringEndBoundaryPreservesEarlierValidSlots() {
        var s = settings; s.startMinute = 90; s.endMinute = 150; s.intervalMinutes = 30
        let reminders = HydrationCoachSchedule.reminders(on: date("2026-03-29T00:00:00+01:00"),
                                                          settings: s, calendar: calendar)
        XCTAssertEqual(reminders.count, 1)
        XCTAssertEqual(reminders[0].scheduledAt, date("2026-03-29T01:30:00+01:00"))
    }

    func testExpiryClearsVisibleWindowAndRestoresNormalGesture() {
        var (session, _) = opened()
        session.expire(at: morning.addingTimeInterval(120))
        XCTAssertNil(session.activeReminder)
        XCTAssertEqual(tap(&session, at: morning.addingTimeInterval(121)), .ignored)
    }

    @MainActor
    func testConfirmationOccursOnlyAfterNewCommit() async throws {
        var events: [String] = []
        let result = try await HydrationCoachCommit.perform(persist: {
            events.append("persisted")
            return true
        }, canConfirm: { true }, confirm: { events.append("confirmed") })
        XCTAssertTrue(result)
        XCTAssertEqual(events, ["persisted", "confirmed"])
    }

    @MainActor
    func testDuplicateReceiptOrUnavailableChannelNeverConfirms() async throws {
        var confirmations = 0
        for (committed, channel) in [(false, true), (true, false), (false, false)] {
            _ = try await HydrationCoachCommit.perform(persist: { committed },
                canConfirm: { channel }, confirm: { confirmations += 1 })
        }
        XCTAssertEqual(confirmations, 0)
    }

    @MainActor
    func testFailedWriteOrOptOutWhileAwaitingWriteNeverConfirms() async throws {
        enum Failure: Error { case diskFull }
        var confirmations = 0
        do {
            _ = try await HydrationCoachCommit.perform(persist: { throw Failure.diskFull },
                canConfirm: { true }, confirm: { confirmations += 1 })
            XCTFail("Expected the persistence failure")
        } catch Failure.diskFull { }
        var optedIn = true
        _ = try await HydrationCoachCommit.perform(persist: {
            optedIn = false
            return true
        }, canConfirm: { optedIn }, confirm: { confirmations += 1 })
        XCTAssertEqual(confirmations, 0)
    }

    @MainActor
    func testDisconnectReconnectOrBackgroundReturnDuringWriteCannotQueueConfirmation() async throws {
        var (session, _) = opened()
        let generation = session.generation
        var confirmations = 0
        _ = try await HydrationCoachCommit.perform(persist: {
            // The command channel may be ready again by the time persistence returns, but this
            // represents a different connection/foreground session and cannot inherit a buzz.
            session.invalidate(at: self.morning.addingTimeInterval(1))
            return true
        }, canConfirm: { session.generation == generation }, confirm: { confirmations += 1 })
        XCTAssertEqual(confirmations, 0)
    }
}
