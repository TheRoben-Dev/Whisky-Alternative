//
//  PlayStats.swift
//  WhiskyKit
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

import Foundation
import os.log

/// Lifetime play statistics for one program.
///
/// Kept apart from ``RunLogHistory`` for two reasons: run history is capped at
/// ten entries, which would make every total wrong after the eleventh launch,
/// and a run log's duration is how long `wine start` ran, which returns as soon
/// as the program has been handed off. Playtime here comes from
/// ``PlaySessionTracker`` watching the program's own process instead.
public struct PlayStats: Codable, Equatable, Sendable {
    /// Days of per-day history kept for the activity chart.
    public static let dailyHistoryDays = 14

    /// Sessions shorter than this are not counted. A program that exits within
    /// a few seconds crashed or bounced to a launcher, and counting it would
    /// inflate the session count without anyone having played.
    public static let minimumSessionLength: TimeInterval = 10

    public private(set) var totalPlaytime: TimeInterval = 0
    public private(set) var sessionCount: Int = 0
    public private(set) var firstPlayed: Date?
    public private(set) var lastPlayed: Date?
    public private(set) var longestSession: TimeInterval = 0
    /// Seconds played per calendar day, keyed by the day's start. Pruned to
    /// ``dailyHistoryDays``.
    public private(set) var daily: [Date: TimeInterval] = [:]

    public init() {}

    public var averageSession: TimeInterval {
        sessionCount > 0 ? totalPlaytime / Double(sessionCount) : 0
    }

    /// Records one finished session.
    ///
    /// A session that crosses midnight is split between the two days, so the
    /// chart shows time on the day it was spent.
    ///
    /// - Returns: `false` when the session was too short to count.
    @discardableResult
    public mutating func record(
        start: Date, end: Date, calendar: Calendar = .current
    ) -> Bool {
        let length = end.timeIntervalSince(start)
        guard length >= Self.minimumSessionLength else { return false }

        totalPlaytime += length
        sessionCount += 1
        longestSession = max(longestSession, length)
        firstPlayed = min(firstPlayed ?? start, start)
        lastPlayed = max(lastPlayed ?? end, end)

        var cursor = start
        while cursor < end {
            let day = calendar.startOfDay(for: cursor)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? end
            let sliceEnd = min(nextDay, end)
            daily[day, default: 0] += sliceEnd.timeIntervalSince(cursor)
            cursor = sliceEnd
        }
        pruneDaily(relativeTo: end, calendar: calendar)
        return true
    }

    /// Seconds played on each of the last ``dailyHistoryDays`` days, oldest
    /// first, with zero for days nothing was played.
    public func recentDays(
        endingAt now: Date = Date(), calendar: Calendar = .current
    ) -> [(day: Date, seconds: TimeInterval)] {
        let today = calendar.startOfDay(for: now)
        return (0 ..< Self.dailyHistoryDays).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (day, daily[day] ?? 0)
        }
    }

    private mutating func pruneDaily(relativeTo now: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: now)
        guard let cutoff = calendar.date(byAdding: .day, value: -(Self.dailyHistoryDays - 1), to: today) else {
            return
        }
        daily = daily.filter { $0.key >= cutoff }
    }
}

/// Persistence for ``PlayStats``, beside the run history in `Program Settings`.
public enum PlayStatsStore {
    private static let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "PlayStatsStore")

    /// `{bottle}/Program Settings/{programName}.play-stats.plist`
    public static func statsURL(for programName: String, in bottleURL: URL) -> URL {
        bottleURL
            .appending(path: "Program Settings")
            .appending(path: programName)
            .appendingPathExtension("play-stats.plist")
    }

    public static func load(for programName: String, in bottleURL: URL) -> PlayStats {
        let url = statsURL(for: programName, in: bottleURL)
        guard let data = try? Data(contentsOf: url) else { return PlayStats() }
        do {
            return try PropertyListDecoder().decode(PlayStats.self, from: data)
        } catch {
            logger.error("Failed to load play stats: \(error.localizedDescription)")
            return PlayStats()
        }
    }

    public static func save(_ stats: PlayStats, for programName: String, in bottleURL: URL) {
        let url = statsURL(for: programName, in: bottleURL)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            try encoder.encode(stats).write(to: url)
        } catch {
            logger.error("Failed to save play stats: \(error.localizedDescription)")
        }
    }

    /// Loads, records one session and saves.
    public static func recordSession(
        start: Date, end: Date, for programName: String, in bottleURL: URL
    ) {
        var stats = load(for: programName, in: bottleURL)
        guard stats.record(start: start, end: end) else { return }
        save(stats, for: programName, in: bottleURL)
    }
}

/// Measures how long a program actually runs.
///
/// `wine start` hands the program off and exits, so the launch call says
/// nothing about when the game closed. This waits for the program's image name
/// to show up in the bottle's process list, then polls until it is gone. The
/// process-list source is injected, as in ``SteamProcessWatch``, so the timing
/// logic is testable without a live bottle.
public struct PlaySessionTracker: Sendable {
    private let pollInterval: Duration
    private let appearTimeout: TimeInterval
    private let runningImageNames: @Sendable () async -> Set<String>?
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - pollInterval: Time between process-list reads. Playtime is only as
    ///     precise as this, which is fine for minutes and hours.
    ///   - appearTimeout: How long to wait for the process to show up. Large
    ///     games under Rosetta can take a while before their process exists.
    ///   - runningImageNames: The bottle's current lowercased image names, or
    ///     `nil` when the list could not be read. A failed read is not taken
    ///     to mean the game exited.
    public init(
        pollInterval: Duration = .seconds(15),
        appearTimeout: TimeInterval = 120,
        runningImageNames: @escaping @Sendable () async -> Set<String>?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.pollInterval = pollInterval
        self.appearTimeout = appearTimeout
        self.runningImageNames = runningImageNames
        self.now = now
    }

    /// Tracks one session of `imageName`.
    ///
    /// - Returns: The session's start and end, or `nil` if the process never
    ///   appeared or the task was cancelled before it exited.
    public func track(imageName: String) async -> (start: Date, end: Date)? {
        let name = imageName.lowercased()

        let deadline = now().addingTimeInterval(appearTimeout)
        var start: Date?
        while start == nil {
            if await runningImageNames()?.contains(name) == true {
                start = now()
                break
            }
            guard now() < deadline else { return nil }
            try? await Task.sleep(for: pollInterval)
            if Task.isCancelled { return nil }
        }

        var lastSeen = start ?? now()
        while true {
            try? await Task.sleep(for: pollInterval)
            if Task.isCancelled { return nil }
            guard let running = await runningImageNames() else { continue }
            if running.contains(name) {
                lastSeen = now()
            } else {
                // The exit happened somewhere in the last interval; the last
                // time it was seen is the honest end rather than a guess.
                return (start ?? lastSeen, lastSeen)
            }
        }
    }
}
