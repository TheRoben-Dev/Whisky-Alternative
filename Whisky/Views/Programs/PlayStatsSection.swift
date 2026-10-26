//
//  PlayStatsSection.swift
//  Whisky
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

import Charts
import SwiftUI
import WhiskyKit

/// Shared formatting so a card and the stats section never disagree on how an
/// hour and a half reads.
enum PlayStatsFormat {
    /// "1h 30m", or "45m" under an hour. Seconds are noise at this scale.
    static func duration(_ seconds: TimeInterval) -> String {
        let allowed: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 3_600 ? [.hours, .minutes] : [.minutes]
        return Duration.seconds(max(seconds, 60))
            .formatted(.units(allowed: allowed, width: .narrow))
    }
}

/// Lifetime stats and the last two weeks of activity for one program.
struct PlayStatsSection: View {
    let program: Program
    @Binding var isExpanded: Bool

    @State private var stats = PlayStats()

    var body: some View {
        Section("program.stats.title", isExpanded: $isExpanded) {
            if stats.sessionCount == 0 {
                Text("program.stats.empty")
                    .foregroundStyle(.secondary)
            } else {
                summary
                activityChart
            }
        }
        .task(id: program.url) { reload() }
        // A session is recorded when the game exits, which is usually while
        // this page is in the background; coming back to the app is the
        // moment the numbers can have changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reload()
        }
    }

    @ViewBuilder
    private var summary: some View {
        LabeledContent("program.stats.total", value: PlayStatsFormat.duration(stats.totalPlaytime))
        LabeledContent("program.stats.sessions", value: stats.sessionCount.formatted())
        LabeledContent("program.stats.average", value: PlayStatsFormat.duration(stats.averageSession))
        LabeledContent("program.stats.longest", value: PlayStatsFormat.duration(stats.longestSession))
        if let lastPlayed = stats.lastPlayed {
            LabeledContent("program.stats.last", value: lastPlayed.formatted(.relative(presentation: .named)))
        }
        if let firstPlayed = stats.firstPlayed {
            LabeledContent("program.stats.first", value: firstPlayed.formatted(date: .abbreviated, time: .omitted))
        }
    }

    private var activityChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("program.stats.recent")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Chart(stats.recentDays(), id: \.day) { day in
                BarMark(
                    x: .value("program.stats.chart.day", day.day, unit: .day),
                    y: .value("program.stats.chart.minutes", day.seconds / 60)
                )
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .frame(height: 120)
            .accessibilityLabel(Text("program.stats.recent"))
        }
        .padding(.vertical, 4)
    }

    private func reload() {
        stats = PlayStatsStore.load(for: program.url.lastPathComponent, in: program.bottle.url)
    }
}
