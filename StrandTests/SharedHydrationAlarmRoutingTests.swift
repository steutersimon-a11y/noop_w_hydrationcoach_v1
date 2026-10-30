import XCTest
import WhoopProtocol
@testable import Strand

/// Shared-slot handoff uses authenticated live alarm evidence and the existing native wake resolver.
final class SharedHydrationAlarmRoutingTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "UTC")!
        return value
    }

    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 30,
                                           hour: hour, minute: minute))!
    }

    private func alarmEvent(_ timestamp: UInt32) -> [UInt8] {
        let bytes: [UInt8] = (0..<4).map { UInt8(truncatingIfNeeded: timestamp >> ($0 * 8)) }
        return frameFromPayload([0] + bytes, type: 48, seq: 1, cmd: 57)
    }

    @MainActor
    func testAlarmMetadataPrecedesSyncAndDuplicateLiveExecutionIsConsumedOnce() {
        let live = LiveState()
        let router = FrameRouter(state: live)
        router.deviceId = "test-whoop"
        let epoch = UInt32(date(7, 30).timeIntervalSince1970)
        let frame = alarmEvent(epoch)
        XCTAssertTrue(parseFrame(frame).ok)
        var order: [String] = []
        live.onSmartAlarmFired = {
            XCTAssertEqual(live.lastSmartAlarmEventDate, self.date(7, 30))
            XCTAssertEqual(live.lastSmartAlarmEventDeviceID, "test-whoop")
            order.append("alarm")
        }
        router.onSyncTrigger = { order.append("sync") }
        router.handle(frame: frame)
        router.handle(frame: frame)
        XCTAssertEqual(order, ["alarm", "sync", "sync"])
    }

    @MainActor
    func testMissingTimeDoesNotBorrowThePreviousAlarmTimestamp() {
        let live = LiveState()
        let router = FrameRouter(state: live)
        var times: [Date?] = []
        live.onSmartAlarmFired = { times.append(live.lastSmartAlarmEventDate) }
        router.handle(frame: alarmEvent(UInt32(date(7, 30).timeIntervalSince1970)))
        router.handle(frame: alarmEvent(0))
        XCTAssertEqual(times, [date(7, 30), nil])
    }

    @MainActor
    func testCorruptAndHistoricalAlarmFramesCannotActivateARoutine() {
        let live = LiveState()
        let router = FrameRouter(state: live)
        var callbacks = 0
        live.onSmartAlarmFired = { callbacks += 1 }
        let epoch = UInt32(date(7, 30).timeIntervalSince1970)
        var corrupt = alarmEvent(epoch)
        corrupt[corrupt.count - 1] ^= 0x80
        router.handle(frame: corrupt)
        router.dispatchLiveGestureIfFresh(frame: alarmEvent(epoch), now: Int(epoch) + 1)
        XCTAssertEqual(callbacks, 0)
        XCTAssertNil(live.lastSmartAlarmEventDate)
    }

    @MainActor
    func testAlarmReadbackEvidenceIsAttributedAndCannotSurviveAConnectionChange() {
        let live = LiveState()
        let router = FrameRouter(state: live)
        router.deviceId = "test-whoop"
        let epoch: UInt32 = 1_787_720_400
        let bytes: [UInt8] = (0..<4).map { UInt8(truncatingIfNeeded: epoch >> ($0 * 8)) }
        router.handle(frame: frameFromPayload([0x42, 1, 1] + bytes + [0, 0, 0, 0],
                                              type: 36, seq: 1, cmd: 67))
        XCTAssertEqual(live.alarmReportedEpoch, Int(epoch))
        XCTAssertEqual(live.alarmReportedDeviceID, "test-whoop")
        XCTAssertNotNil(live.alarmReportedAt)
        live.clearBiometrics()
        XCTAssertNil(live.alarmReportedEpoch)
        XCTAssertNil(live.alarmReportedDeviceID)
        XCTAssertNil(live.alarmReportedAt)
        router.handle(frame: frameFromPayload([0x42, 1, 0, 0, 0, 0],
                                              type: 36, seq: 2, cmd: 67))
        XCTAssertEqual(live.alarmReportedEpoch, 0, "an explicit empty alarm is evidence, not success")
        router.family = .whoop4
        XCTAssertNil(live.alarmReportedEpoch)
    }

    func testTodaysNativeWakeIncludesAlreadyPassedAndMidnightTimes() {
        for minute in 0..<1440 {
            let wake = AppModel.scheduledSmartAlarmDate(on: date(23, 59), minutes: minute,
                                                       weekdays: [], calendar: calendar)
            XCTAssertEqual(wake, date(minute / 60, minute % 60))
        }
    }

    func testNativeWeekdayOverridesRemainTheOnlyWakeSource() {
        XCTAssertEqual(calendar.component(.weekday, from: date(12)), 6)
        XCTAssertNil(AppModel.scheduledSmartAlarmDate(on: date(12), minutes: 450,
                                                      weekdays: [2, 3, 4, 5], calendar: calendar))
        XCTAssertEqual(AppModel.scheduledSmartAlarmDate(on: date(12), minutes: 450,
                                                        weekdays: [6], overrides: [6: 510], calendar: calendar),
                       date(8, 30))
        XCTAssertEqual(AppModel.nextSmartAlarmDate(minutes: 450, weekdays: [6], overrides: [6: 510],
                                                   from: date(6), calendar: calendar), date(8, 30))
    }
}
