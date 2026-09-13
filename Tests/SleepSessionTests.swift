import XCTest
@testable import Cobux

/// Guards "last night" actually meaning last night.
///
/// Reported by Rajan through TestFlight on 2026-09-03: "I woke up 8 hrs sum
/// sleep but this data is collected wrong." The query summed every asleep
/// interval in a 36-hour window, so read in the evening it also counted the tail
/// of the night before and any nap since.
final class SleepSessionTests: XCTestCase {

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day,
                                                   hour: hour, minute: minute))!
    }

    func testOneNightIsOneSession() {
        let sessions = HealthContextService.sleepSessions(from: [
            (at(2, 23), at(3, 3)), (at(3, 3), at(3, 7)),
        ])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].duration / 3600, 8, accuracy: 0.01)
    }

    /// The reported bug: last night plus the previous night's tail must not add.
    func testTwoNightsAreTwoSessionsAndOnlyTheLastCounts() {
        let sessions = HealthContextService.sleepSessions(from: [
            (at(1, 23), at(2, 7)),   // the night before — 8h
            (at(2, 23), at(3, 7)),   // last night — 8h
        ])
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.last!.duration / 3600, 8, accuracy: 0.01,
                       "the most recent night must stand alone, not sum to 16")
    }

    /// Two sources writing the same night must not double-count it.
    func testOverlappingSourcesDoNotDoubleCount() {
        let sessions = HealthContextService.sleepSessions(from: [
            (at(2, 23), at(3, 7)),        // WHOOP
            (at(2, 23, 30), at(3, 6)),    // the phone, fully inside it
        ])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].duration / 3600, 8, accuracy: 0.01,
                       "eight hours reported twice is still eight hours")
    }

    func testPartialOverlapCountsTheUnionOnce() {
        let sessions = HealthContextService.sleepSessions(from: [
            (at(2, 23), at(3, 4)),
            (at(3, 3), at(3, 7)),
        ])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].duration / 3600, 8, accuracy: 0.01)
    }

    /// An afternoon nap is its own session, so it can be rejected on length
    /// rather than silently inflating last night.
    func testNapIsASeparateSession() {
        let sessions = HealthContextService.sleepSessions(from: [
            (at(2, 23), at(3, 7)),
            (at(3, 14), at(3, 14, 25)),
        ])
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.last!.duration / 60, 25, accuracy: 0.01)
    }

    func testNoSamplesIsNoSessions() {
        XCTAssertTrue(HealthContextService.sleepSessions(from: []).isEmpty)
    }
}
