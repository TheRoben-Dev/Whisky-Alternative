//
//  PlayStatsTests.swift
//  WhiskyKitTests
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

@testable import WhiskyKit
import XCTest

final class PlayStatsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    // MARK: - PlayStats

    func testRecordAccumulatesTotals() {
        var stats = PlayStats()
        XCTAssertTrue(stats.record(start: date(1, 10), end: date(1, 11), calendar: calendar))
        XCTAssertTrue(stats.record(start: date(2, 10), end: date(2, 13), calendar: calendar))

        XCTAssertEqual(stats.sessionCount, 2)
        XCTAssertEqual(stats.totalPlaytime, 4 * 3600)
        XCTAssertEqual(stats.longestSession, 3 * 3600)
        XCTAssertEqual(stats.averageSession, 2 * 3600)
        XCTAssertEqual(stats.firstPlayed, date(1, 10))
        XCTAssertEqual(stats.lastPlayed, date(2, 13))
    }

    func testShortSessionIsIgnored() {
        var stats = PlayStats()
        XCTAssertFalse(stats.record(start: date(1, 10), end: date(1, 10).addingTimeInterval(3), calendar: calendar))
        XCTAssertEqual(stats, PlayStats())
    }

    func testSessionAcrossMidnightIsSplitBetweenDays() {
        var stats = PlayStats()
        stats.record(start: date(1, 23), end: date(2, 1), calendar: calendar)

        let days = stats.recentDays(endingAt: date(2, 12), calendar: calendar)
        XCTAssertEqual(days.count, PlayStats.dailyHistoryDays)
        XCTAssertEqual(days.last?.seconds, 3600)
        XCTAssertEqual(days[days.count - 2].seconds, 3600)
    }

    func testDailyHistoryIsPruned() {
        var stats = PlayStats()
        stats.record(start: date(1, 10), end: date(1, 11), calendar: calendar)
        stats.record(start: date(25, 10), end: date(25, 11), calendar: calendar)

        XCTAssertEqual(stats.daily.count, 1)
        XCTAssertEqual(stats.totalPlaytime, 2 * 3600)
    }

    // MARK: - PlayStatsStore

    func testStoreRoundTripsAndRecords() throws {
        let bottleURL = FileManager.default.temporaryDirectory.appending(path: "playstats_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bottleURL) }

        XCTAssertEqual(PlayStatsStore.load(for: "game.exe", in: bottleURL), PlayStats())

        let start = Date()
        PlayStatsStore.recordSession(start: start, end: start.addingTimeInterval(600), for: "game.exe", in: bottleURL)
        PlayStatsStore.recordSession(start: start, end: start.addingTimeInterval(1), for: "game.exe", in: bottleURL)

        let loaded = PlayStatsStore.load(for: "game.exe", in: bottleURL)
        XCTAssertEqual(loaded.sessionCount, 1)
        XCTAssertEqual(loaded.totalPlaytime, 600, accuracy: 0.001)
    }

    // MARK: - PlaySessionTracker

    /// A scripted process list and a clock that advances one minute per read.
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var reads: [Set<String>?]
        private var clock = Date(timeIntervalSince1970: 0)

        init(_ reads: [Set<String>?]) { self.reads = reads }

        func next() -> Set<String>? {
            lock.withLock {
                clock.addTimeInterval(60)
                return reads.isEmpty ? [] : reads.removeFirst()
            }
        }

        func now() -> Date { lock.withLock { clock } }
    }

    private func tracker(_ script: Script, appearTimeout: TimeInterval = 600) -> PlaySessionTracker {
        PlaySessionTracker(
            pollInterval: .milliseconds(1),
            appearTimeout: appearTimeout,
            runningImageNames: { script.next() },
            now: { script.now() }
        )
    }

    func testTrackerMeasuresFromAppearanceToLastSighting() async {
        let script = Script([[], ["game.exe"], ["game.exe"], nil, ["game.exe"], ["steam.exe"]])
        let session = await tracker(script).track(imageName: "Game.exe")

        // Appears on read 2 (t=120), last seen on read 5 (t=300); the failed
        // read in between is not an exit.
        XCTAssertEqual(session?.start, Date(timeIntervalSince1970: 120))
        XCTAssertEqual(session?.end, Date(timeIntervalSince1970: 300))
    }

    func testTrackerGivesUpWhenProcessNeverAppears() async {
        let script = Script([[], [], [], []])
        let session = await tracker(script, appearTimeout: 150).track(imageName: "game.exe")
        XCTAssertNil(session)
    }
}
