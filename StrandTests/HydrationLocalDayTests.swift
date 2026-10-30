import XCTest
@testable import Strand

final class HydrationLocalDayTests: XCTestCase {
    func testDayKeysFollowTravelWithoutRestartingOrChangingStoredDays() {
        let instant = ISO8601DateFormatter().date(from: "2026-10-29T00:30:00Z")!
        XCTAssertEqual(Repository.localDayKey(instant, timeZone: TimeZone(identifier: "Europe/Berlin")!), "2026-10-29")
        XCTAssertEqual(Repository.localDayKey(instant, timeZone: TimeZone(identifier: "America/Los_Angeles")!), "2026-10-28")
        XCTAssertEqual(Repository.localDayKey(instant, timeZone: TimeZone(identifier: "Europe/Berlin")!), "2026-10-29")
    }
}
