import XCTest
@testable import HydrationCoach

final class HydrationRoutineTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private var wake: Date { date("2026-10-29T07:30:00+01:00") }
    private var settings: HydrationCoachSettings { HydrationCoachSettings(enabled: true) }
    private func plan(_ settings: HydrationCoachSettings? = nil, wake: Date? = nil) -> HydrationRoutinePlan {
        HydrationRoutinePlanner.plan(wakeAt: wake ?? self.wake, settings: settings ?? self.settings,
                                     calendar: calendar)!
    }

    func testLegacySettingsKeepSavedPreferencesAndAddBottleDefault() throws {
        let legacy = Data("""
        {"enabled":true,"personalGoalML":3500,"servingML":300,"startMinute":480,
         "endMinute":1320,"intervalMinutes":80}
        """.utf8)
        let decoded = try JSONDecoder().decode(HydrationCoachSettings.self, from: legacy)
        XCTAssertTrue(decoded.enabled)
        XCTAssertEqual(decoded.personalGoalML, 3_500)
        XCTAssertEqual(decoded.servingML, 300)
        XCTAssertEqual(decoded.bottleML, 500)
        XCTAssertEqual(decoded.endMinute, 1_320)
        XCTAssertEqual(decoded.intervalMinutes, 80)
        XCTAssertEqual(try JSONDecoder().decode(HydrationCoachSettings.self,
                       from: JSONEncoder().encode(decoded)), decoded)
        let empty = try JSONDecoder().decode(HydrationCoachSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, HydrationCoachSettings())
    }

    func testNewPlannerUsesOnlyExternallyResolvedWakeDate() {
        var a = settings
        a.startMinute = -999
        XCTAssertTrue(a.isValid)
        XCTAssertEqual(plan(a), plan())
        XCTAssertNil(HydrationRoutinePlanner.plan(wakeAt: nil, settings: a, calendar: calendar))
        a.enabled = false
        XCTAssertNil(HydrationRoutinePlanner.plan(wakeAt: wake, settings: a, calendar: calendar))
    }

    func testFirstAlarmIsOneIntervalAfterWakeAndBedtimeIsQuiet() {
        let plan = plan()
        XCTAssertEqual(plan.slots.first?.scheduledAt, date("2026-10-29T08:30:00+01:00"))
        XCTAssertEqual(plan.slots.last?.scheduledAt, date("2026-10-29T22:30:00+01:00"))
        XCTAssertEqual(plan.bedtimeAt, date("2026-10-29T23:30:00+01:00"))
        XCTAssertEqual(plan.checkpoints.count, 16)
        XCTAssertEqual(plan.slots.count, 15)
        XCTAssertTrue(plan.checkpoints.last!.isBedtimeBoundary)
        XCTAssertEqual(plan.checkpoints.last?.cumulativeTargetML, 3_000)
        XCTAssertNil(plan.nextSlot(after: plan.bedtimeAt, totalML: 0))
        XCTAssertNil(plan.nextSlot(after: plan.slots.last!.scheduledAt, totalML: 0))
    }

    func testSixtyAndEightyMinutePlansHaveProportionalLargerPortions() {
        let hourly = plan()
        var eightySettings = settings
        eightySettings.intervalMinutes = 80
        let eighty = plan(eightySettings)
        XCTAssertEqual(hourly.checkpoints.map(\.recommendedML).reduce(0, +), 3_000)
        XCTAssertEqual(Set(hourly.checkpoints.map(\.recommendedML)), [187, 188])
        XCTAssertEqual(eighty.checkpoints.count, 12)
        XCTAssertTrue(eighty.checkpoints.allSatisfy { $0.recommendedML == 250 })
        XCTAssertEqual(eighty.slots.first?.scheduledAt, date("2026-10-29T08:50:00+01:00"))
    }

    func testArbitraryIntervalsAndGoalsHaveExactRoundedCumulativeTotals() {
        for interval in [15, 17, 23, 60, 75, 80, 95, 137, 240] {
            for goal in [250, 1_001, 3_000, 3_333, 10_000] {
                var s = settings
                s.intervalMinutes = interval
                s.personalGoalML = goal
                let plan = plan(s)
                XCTAssertEqual(plan.checkpoints.map(\.recommendedML).reduce(0, +), goal)
                XCTAssertEqual(plan.checkpoints.last?.cumulativeTargetML, goal)
                var running = 0
                for slot in plan.checkpoints {
                    running += slot.recommendedML
                    XCTAssertEqual(running, slot.cumulativeTargetML)
                    XCTAssertGreaterThanOrEqual(slot.recommendedML, 0)
                }
                XCTAssertEqual(Set(plan.checkpoints.map(\.id)).count, plan.checkpoints.count)
                XCTAssertTrue(plan.slots.allSatisfy { $0.scheduledAt < plan.bedtimeAt })
            }
        }
        var s = settings
        s.intervalMinutes = 75
        let uneven = plan(s)
        XCTAssertEqual(uneven.checkpoints.count, 13)
        XCTAssertEqual(uneven.checkpoints.last!.scheduledAt.timeIntervalSince(
            uneven.checkpoints[11].scheduledAt), 60 * 60)
    }

    func testEarlyWaterAndGoalSuppressFutureAlarmsWithoutCatchup() {
        let plan = plan()
        let at = date("2026-10-29T08:00:00+01:00")
        XCTAssertEqual(plan.nextSlot(after: at, totalML: 500)?.scheduledAt,
                       date("2026-10-29T10:30:00+01:00"))
        XCTAssertNil(plan.nextSlot(after: at, totalML: 3_000))
        XCTAssertNil(plan.nextSlot(after: at, totalML: 5_000))
        for badTotal in [-1.0, .nan, .infinity] {
            XCTAssertNil(plan.nextSlot(after: at, totalML: badTotal))
        }
        let lateDismissal = date("2026-10-29T12:31:00+01:00")
        XCTAssertEqual(plan.nextSlot(after: at, totalML: 0, notBefore: lateDismissal)?.scheduledAt,
                       date("2026-10-29T13:30:00+01:00"))
        XCTAssertEqual(plan.nextSlot(after: date("2026-10-29T12:30:00+01:00"), totalML: 0)?.scheduledAt,
                       date("2026-10-29T13:30:00+01:00"))
    }

    func testLateStartCannotTurnTheCumulativeDeficitIntoAHugeRecommendedDrink() {
        let plan = plan()
        let late = date("2026-10-29T17:31:00+01:00")
        let next = plan.nextSlot(after: late, totalML: 0)!
        XCTAssertGreaterThan(next.cumulativeTargetML, 2_000)
        XCTAssertEqual(plan.recommendedML(at: late, totalML: 0), next.recommendedML)
        XCTAssertLessThanOrEqual(plan.recommendedML(at: late, totalML: 0), 188)
        XCTAssertEqual(plan.recommendedML(at: late, totalML: 3_000), 0)
        var largeGoal = settings
        largeGoal.personalGoalML = 10_000
        largeGoal.intervalMinutes = 240
        let larger = self.plan(largeGoal)
        XCTAssertEqual(larger.recommendedML(at: wake, totalML: 0), 500)
        XCTAssertEqual(larger.checkpoints.last?.cumulativeTargetML, 10_000)
    }

    func testModeNeedsAnActualCurrentDayWakeDismissal() throws {
        let plan = plan()
        XCTAssertEqual(HydrationRoutinePlanner.mode(at: wake.addingTimeInterval(-1), plan: plan,
                                                    activation: nil), .night)
        XCTAssertEqual(HydrationRoutinePlanner.mode(at: wake, plan: plan, activation: nil), .wakeRinging)
        let dismissed = wake.addingTimeInterval(60)
        let activation = HydrationRoutineActivation(wakeAt: wake, dismissedAt: dismissed, calendar: calendar)
        XCTAssertEqual(HydrationRoutinePlanner.mode(at: wake, plan: plan, activation: activation), .wakeRinging)
        XCTAssertEqual(HydrationRoutinePlanner.mode(at: dismissed, plan: plan,
                                                    activation: activation), .hydration)
        XCTAssertEqual(HydrationRoutinePlanner.mode(at: plan.bedtimeAt, plan: plan,
                                                    activation: activation), .night)
        let restored = try JSONDecoder().decode(HydrationRoutineActivation.self,
                                                from: JSONEncoder().encode(activation))
        XCTAssertEqual(restored, activation)
        XCTAssertEqual(HydrationRoutinePlanner.mode(at: dismissed, plan: plan,
                                                    activation: restored), .hydration)
        let yesterday = HydrationRoutineActivation(wakeAt: wake.addingTimeInterval(-86_400),
            dismissedAt: wake.addingTimeInterval(-86_300), calendar: calendar)
        XCTAssertEqual(HydrationRoutinePlanner.mode(at: dismissed, plan: plan,
                                                    activation: yesterday), .wakeRinging)
        XCTAssertEqual(HydrationRoutinePlanner.mode(at: dismissed, plan: nil,
                                                    activation: activation), .night)
    }

    func testGoalAndIntervalEditsDoNotInvalidateRecordedWakeDismissal() {
        let activation = HydrationRoutineActivation(wakeAt: wake, dismissedAt: wake, calendar: calendar)
        var changed = settings
        changed.personalGoalML = 4_000
        changed.intervalMinutes = 80
        XCTAssertTrue(activation.matches(plan(changed)))
        var zone = calendar
        zone.timeZone = TimeZone(identifier: "UTC")!
        let other = HydrationRoutinePlanner.plan(wakeAt: wake, settings: settings, calendar: zone)!
        XCTAssertFalse(activation.matches(other))
    }

    func testBedtimeAndPreferenceBoundsFailClosedAndMidnightEndsWakeDay() {
        for value in [-1, 1_440, Int.max] {
            var s = settings; s.endMinute = value
            XCTAssertNil(HydrationRoutinePlanner.plan(wakeAt: wake, settings: s, calendar: calendar))
        }
        for value in [0, 14, 241, Int.max] {
            var s = settings; s.intervalMinutes = value
            XCTAssertNil(HydrationRoutinePlanner.plan(wakeAt: wake, settings: s, calendar: calendar))
        }
        for value in [0, 99, 2_001] {
            var s = settings; s.bottleML = value
            XCTAssertFalse(s.isValid)
        }
        var earlyBed = settings
        earlyBed.endMinute = 450
        XCTAssertNil(HydrationRoutinePlanner.plan(wakeAt: wake, settings: earlyBed, calendar: calendar))
        earlyBed.endMinute = 0
        XCTAssertEqual(plan(earlyBed).bedtimeAt, date("2026-10-30T00:00:00+01:00"))
    }

    func testDaylightSavingUsesElapsedIntervalsAndLocalBedtime() {
        var s = settings
        s.endMinute = 270
        let spring = plan(s, wake: date("2026-03-29T01:30:00+01:00"))
        XCTAssertEqual(spring.slots.map(\.scheduledAt), [date("2026-03-29T03:30:00+02:00")])
        XCTAssertEqual(spring.checkpoints.map(\.recommendedML), [1_500, 1_500])
        let fall = plan(s, wake: date("2026-10-25T01:30:00+02:00"))
        XCTAssertEqual(fall.slots.map(\.scheduledAt), [date("2026-10-25T02:30:00+02:00"),
            date("2026-10-25T02:30:00+01:00"), date("2026-10-25T03:30:00+01:00")])
        XCTAssertEqual(fall.checkpoints.map(\.recommendedML), [750, 750, 750, 750])
        XCTAssertEqual(Set(fall.slots.map(\.id)).count, 3)
    }
}

final class HydrationTapAggregatorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var settings: HydrationCoachSettings { HydrationCoachSettings(enabled: true) }

    func testSingleDoubleTapCommitsOneGlassOnlyAfterThreeSeconds() {
        var taps = HydrationTapAggregator()
        XCTAssertTrue(taps.receive(eventID: "a", eventDate: start, receivedAt: start,
                                   settings: settings).isEmpty)
        XCTAssertEqual(taps.nextDeadline, start.addingTimeInterval(3))
        XCTAssertNil(taps.flush(at: start.addingTimeInterval(2.999)))
        let entry = taps.flush(at: start.addingTimeInterval(3))!
        XCTAssertEqual(entry.id, "a")
        XCTAssertEqual(entry.volumeML, 250)
        XCTAssertEqual(entry.gestureCount, 1)
        XCTAssertEqual(entry.eventIDs, ["a"])
        XCTAssertEqual(entry.eventDates, [start])
        XCTAssertNil(taps.flush(at: start.addingTimeInterval(4)))
    }

    func testTwoDistinctDoubleTapsCommitOneBottleAndExposeBothReceipts() {
        var taps = HydrationTapAggregator()
        _ = taps.receive(eventID: "a", eventDate: start, receivedAt: start, settings: settings)
        let second = start.addingTimeInterval(2)
        let result = taps.receive(eventID: "b", eventDate: second, receivedAt: second, settings: settings)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "a")
        XCTAssertEqual(result[0].volumeML, 500)
        XCTAssertEqual(result[0].gestureCount, 2)
        XCTAssertEqual(result[0].eventIDs, ["a", "b"])
        XCTAssertEqual(result[0].eventDates, [start, second])
        XCTAssertNil(taps.nextDeadline)
        XCTAssertNil(taps.flush(at: start.addingTimeInterval(4)))
        XCTAssertTrue(taps.receive(eventID: "a", eventDate: start, receivedAt: second,
                                   settings: settings).isEmpty)
        XCTAssertTrue(taps.receive(eventID: "b", eventDate: second, receivedAt: second,
                                   settings: settings).isEmpty)
    }

    func testJustInsideWindowIsBottleAndDeadlineStartsAnotherGlass() {
        var taps = HydrationTapAggregator()
        _ = taps.receive(eventID: "a", eventDate: start, receivedAt: start, settings: settings)
        let inside = start.addingTimeInterval(2.999)
        XCTAssertEqual(taps.receive(eventID: "b", eventDate: inside, receivedAt: inside,
                                    settings: settings).first?.volumeML, 500)
        let boundary = start.addingTimeInterval(3)
        _ = taps.receive(eventID: "c", eventDate: boundary, receivedAt: boundary, settings: settings)
        let late = start.addingTimeInterval(6)
        let previous = taps.receive(eventID: "d", eventDate: late, receivedAt: late, settings: settings)
        XCTAssertEqual(previous.first?.id, "c")
        XCTAssertEqual(previous.first?.volumeML, 250)
        XCTAssertEqual(taps.flush(at: late.addingTimeInterval(3))?.id, "d")
    }

    func testTimerAndSecondTapOrderingAtDeadlineCannotChangeLoggedAmount() {
        for timerFirst in [false, true] {
            var taps = HydrationTapAggregator()
            _ = taps.receive(eventID: "a", eventDate: start, receivedAt: start, settings: settings)
            var entries: [HydrationGestureEntry] = []
            let deadline = start.addingTimeInterval(3)
            if timerFirst, let entry = taps.flush(at: deadline) { entries.append(entry) }
            entries += taps.receive(eventID: "b", eventDate: deadline,
                                    receivedAt: deadline, settings: settings)
            if let entry = taps.flush(at: deadline.addingTimeInterval(3)) { entries.append(entry) }
            XCTAssertEqual(entries.map(\.volumeML), [250, 250])
            XCTAssertEqual(entries.map(\.id), ["a", "b"])
        }
    }

    func testDuplicateSameSecondDistinctEventsAndRecordedContainerSizes() {
        var taps = HydrationTapAggregator()
        var custom = settings
        custom.servingML = 300; custom.bottleML = 750
        _ = taps.receive(eventID: "a", eventDate: start, receivedAt: start, settings: custom)
        XCTAssertTrue(taps.receive(eventID: "a", eventDate: start, receivedAt: start,
                                   settings: custom).isEmpty)
        XCTAssertEqual(taps.receive(eventID: "b", eventDate: start,
            receivedAt: start.addingTimeInterval(0.5), settings: custom).first?.volumeML, 750)
        _ = taps.receive(eventID: "c", eventDate: start, receivedAt: start, settings: custom)
        XCTAssertEqual(taps.flush(at: start.addingTimeInterval(3))?.volumeML, 300)
    }

    func testOldFutureMissingEventsAndCancellationCannotCreateSpeculativeCredit() {
        var taps = HydrationTapAggregator()
        XCTAssertTrue(taps.receive(eventID: "missing", eventDate: nil, receivedAt: start,
                                   settings: settings).isEmpty)
        XCTAssertTrue(taps.receive(eventID: "future", eventDate: start.addingTimeInterval(1),
                                   receivedAt: start, settings: settings).isEmpty)
        _ = taps.receive(eventID: "a", eventDate: start, receivedAt: start, settings: settings)
        XCTAssertTrue(taps.receive(eventID: "old", eventDate: start.addingTimeInterval(-1),
                                   receivedAt: start, settings: settings).isEmpty)
        taps.invalidate()
        XCTAssertNil(taps.flush(at: start.addingTimeInterval(4)))
        XCTAssertTrue(taps.receive(eventID: "a", eventDate: start,
                                   receivedAt: start.addingTimeInterval(4), settings: settings).isEmpty)
    }

    func testLargeEventTimeGapDoesNotBecomeBottleWhenDeliveryIsBatched() {
        var taps = HydrationTapAggregator()
        _ = taps.receive(eventID: "a", eventDate: start.addingTimeInterval(-10),
                         receivedAt: start, settings: settings)
        let result = taps.receive(eventID: "b", eventDate: start,
                                  receivedAt: start.addingTimeInterval(1), settings: settings)
        XCTAssertEqual(result.first?.volumeML, 250)
        XCTAssertEqual(taps.flush(at: start.addingTimeInterval(4))?.volumeML, 250)
    }

    func testFreeLoggingDoesNotDependOnAReminderOrDailyGoal() {
        var taps = HydrationTapAggregator()
        for i in 0..<20 {
            let at = start.addingTimeInterval(Double(i * 10))
            _ = taps.receive(eventID: "tap-\(i)", eventDate: at, receivedAt: at, settings: settings)
            XCTAssertEqual(taps.flush(at: at.addingTimeInterval(3))?.volumeML, 250)
        }
    }
}
