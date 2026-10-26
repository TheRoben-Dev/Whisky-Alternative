//
//  LibraryModel.swift
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

import AppKit
import Combine
import Foundation
import WhiskyKit

/// How the library grid is ordered.
enum LibrarySort: String, CaseIterable, Identifiable {
    case recent
    case playtime
    case name
    case bottle

    var id: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .recent: "library.sort.recent"
        case .playtime: "library.sort.playtime"
        case .name: "library.sort.name"
        case .bottle: "library.sort.bottle"
        }
    }
}

/// How the library grid draws its entries.
enum LibraryLayout: String, CaseIterable, Identifiable {
    /// Portrait box art, the way console launchers show a library.
    case covers
    /// Wide cards coloured by the icon, which suit programs without art.
    case cards

    var id: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .covers: "library.layout.covers"
        case .cards: "library.layout.cards"
        }
    }

    var systemImage: String {
        switch self {
        case .covers: "rectangle.portrait.on.rectangle.portrait"
        case .cards: "rectangle.grid.2x2"
        }
    }
}

/// A library entry plus what the grid needs to draw it. `bottleName`,
/// `lastPlayed` and `playtime` are presentation, which is why they live here
/// rather than in ``LibraryEntry``.
struct LibraryRow: Identifiable {
    let item: LibraryEntry
    let bottleName: String?
    let lastPlayed: Date?
    /// Lifetime playtime from ``PlayStats``. Steam games count sessions
    /// started from Whisky, timed by their ``SteamClientOrchestrator``.
    let playtime: TimeInterval

    var id: String { item.id }
}

/// Builds the library and owns what is currently starting or running.
///
/// A view model rather than view state because the running half comes from a
/// ``SteamClientOrchestrator`` per bottle, and those are long-lived objects with
/// their own pollers: the library previously made one per launch and threw it
/// away, so everything it published (the launch phase, the running App IDs, the
/// launch error) went nowhere.
@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var rows: [LibraryRow] = []
    @Published var launchError: String?
    @Published var toast: ToastData?

    /// App IDs with a launch in flight, per bottle.
    @Published private var steamLaunching: [URL: Set<Int>] = [:]
    /// App IDs whose own processes are in the bottle's process list.
    @Published private var steamRunning: [URL: Set<Int>] = [:]
    /// Programs whose launch call has not returned yet.
    @Published private var programLaunching: Set<URL> = []

    var sort: LibrarySort = .recent {
        didSet {
            guard sort != oldValue else { return }
            rows = sorted(rows)
        }
    }

    private var orchestrators: [URL: SteamClientOrchestrator] = [:]
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - State

    /// What a card should be showing.
    ///
    /// Running is checked before launching because a Steam launch stays in its
    /// grace period for up to two minutes while shaders precompile, which can
    /// outlast the game actually appearing.
    func state(for entry: LibraryEntry) -> LibraryEntryState {
        switch entry.launch {
        case let .program(url):
            programLaunching.contains(url) ? .launching : .idle
        case let .steam(appID):
            if steamRunning[entry.bottleURL]?.contains(appID) == true {
                .running
            } else if steamLaunching[entry.bottleURL]?.contains(appID) == true {
                .launching
            } else {
                .idle
            }
        }
    }

    // MARK: - Building

    /// Rebuilds every row in one pass.
    ///
    /// Rebuilt whole rather than per card: enumerating Steam walks
    /// `libraryfolders.vdf` and every run log lookup is a plist read, so doing
    /// it inside a card turns scrolling into disk traffic.
    func reload(bottles: [Bottle]) async {
        var built: [LibraryRow] = []
        let showBottleName = bottles.count > 1
        let routed = GameRouting().lastLaunches()

        for bottle in bottles {
            let url = bottle.url
            // Pins come straight from settings, which is a main-actor read.
            // Steam is the part that walks the filesystem, so only that goes
            // off the main actor, and it needs nothing but the bottle URL.
            let pinned = PinnedLibrarySource.items(inBottleAt: url, settings: bottle.settings)
            let steam = await Task.detached { SteamLibrarySource.entries(inBottleAt: url) }.value

            let merged = LibraryCatalogue.merge([pinned, steam])
            let covered = await Task.detached { LibraryCoverStore.applyingCustomCovers(to: merged) }.value

            for item in covered {
                built.append(
                    LibraryRow(
                        item: item,
                        bottleName: showBottleName ? bottle.settings.name : nil,
                        lastPlayed: lastPlayed(for: item, routed: routed),
                        playtime: playtime(for: item)
                    )
                )
            }

            trackSteam(in: bottle)
        }

        rows = sorted(built)
    }

    /// When an entry was last started in Whisky.
    private func lastPlayed(
        for item: LibraryEntry, routed: [Int: Date]
    ) -> Date? {
        switch item.launch {
        case let .program(url):
            RunLogStore.load(for: url.lastPathComponent, in: item.bottleURL)
                .entries.map(\.startTime).max()
        case let .steam(appID):
            // A session's end is later than its launch, so the stats are the
            // fresher answer once the game has been played and closed.
            [routed[appID], stats(for: item).lastPlayed].compactMap(\.self).max()
        }
    }

    private func playtime(for item: LibraryEntry) -> TimeInterval {
        stats(for: item).totalPlaytime
    }

    private func stats(for item: LibraryEntry) -> PlayStats {
        switch item.launch {
        case let .program(url):
            PlayStatsStore.load(for: url.lastPathComponent, in: item.bottleURL)
        case let .steam(appID):
            PlayStatsStore.load(for: PlayStatsStore.steamName(appID: appID), in: item.bottleURL)
        }
    }

    /// Re-reads playtime and last played for every row, after a Steam game's
    /// session was saved. Cheaper than a reload: nothing is enumerated.
    private func refreshPlayStats() {
        let routed = GameRouting().lastLaunches()
        rows = sorted(rows.map { row in
            LibraryRow(
                item: row.item,
                bottleName: row.bottleName,
                lastPlayed: lastPlayed(for: row.item, routed: routed),
                playtime: playtime(for: row.item)
            )
        })
    }

    /// Launchers last whatever the sort is. A storefront client is how you reach
    /// a game, not one of them, and it would otherwise take the top of the grid
    /// on recency because every game launch runs it.
    private func sorted(_ rows: [LibraryRow]) -> [LibraryRow] {
        rows.sorted { first, second in
            if first.item.isLauncher != second.item.isLauncher {
                return second.item.isLauncher
            }
            return switch sort {
            case .recent: byRecency(first, second)
            case .playtime: byPlaytime(first, second)
            case .name: byName(first, second)
            case .bottle: byBottle(first, second)
            }
        }
    }

    private func byRecency(_ first: LibraryRow, _ second: LibraryRow) -> Bool {
        switch (first.lastPlayed, second.lastPlayed) {
        case let (lhs?, rhs?): lhs > rhs
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): byName(first, second)
        }
    }

    private func byPlaytime(_ first: LibraryRow, _ second: LibraryRow) -> Bool {
        guard first.playtime != second.playtime else { return byRecency(first, second) }
        return first.playtime > second.playtime
    }

    private func byName(_ first: LibraryRow, _ second: LibraryRow) -> Bool {
        first.item.name.localizedStandardCompare(second.item.name) == .orderedAscending
    }

    private func byBottle(_ first: LibraryRow, _ second: LibraryRow) -> Bool {
        let lhs = first.bottleName ?? ""
        let rhs = second.bottleName ?? ""
        guard lhs == rhs else { return lhs.localizedStandardCompare(rhs) == .orderedAscending }
        return byName(first, second)
    }
}

// MARK: - Covers

extension LibraryModel {
    /// Makes the image at `source` the cover for `row`, then redraws the grid.
    func setCover(from source: URL, for row: LibraryRow, bottles: [Bottle]) async {
        do {
            let stored = try LibraryCoverStore.setCustomCover(from: source, for: row.item)
            // A replacement in the same format lands at the same path, and the
            // cache is keyed by path, so without this the old cover stays up.
            await IconCache.shared.invalidate(url: stored)
            await reload(bottles: bottles)
        } catch {
            toast = ToastData(message: String(localized: "library.cover.failed"), style: .error)
        }
    }

    func resetCover(for row: LibraryRow, bottles: [Bottle]) async {
        if let current = row.item.coverURL {
            await IconCache.shared.invalidate(url: current)
        }
        LibraryCoverStore.removeCustomCover(for: row.item)
        await reload(bottles: bottles)
    }
}

// MARK: - Launching

extension LibraryModel {
    func launch(_ row: LibraryRow, bottles: [Bottle]) {
        guard let bottle = bottles.first(where: { $0.url == row.item.bottleURL }) else { return }

        switch row.item.launch {
        case let .program(url):
            launchProgram(at: url, in: bottle)
        case let .steam(appID):
            let games = SteamLibrary.enumerate(bottleURL: bottle.url)
            guard let game = games.first(where: { $0.appId == appID }) else {
                launchError = String(localized: "library.launch.steamGameMissing")
                return
            }
            orchestrator(for: bottle).launch(game)
        }
    }

    /// Stops a running Steam game. Programs have no per-entry stop: the launch
    /// path returns long before the program exits, so there is nothing tracked
    /// to stop. The bottle's own stop is what reaches those.
    func stop(_ row: LibraryRow, bottles: [Bottle]) {
        guard case let .steam(appID) = row.item.launch,
              let bottle = bottles.first(where: { $0.url == row.item.bottleURL })
        else { return }

        let games = SteamLibrary.enumerate(bottleURL: bottle.url)
        guard let game = games.first(where: { $0.appId == appID }) else { return }
        Task { await orchestrator(for: bottle).stop(game) }
    }

    private func launchProgram(at url: URL, in bottle: Bottle) {
        // Through the bottle's own program list where possible, so the launch
        // picks up that program's overrides rather than only the bottle's.
        guard let program = bottle.programs.first(where: { $0.url == url }) else {
            programLaunching.insert(url)
            Task {
                defer { programLaunching.remove(url) }
                do {
                    try await Wine.runProgram(at: url, bottle: bottle)
                } catch {
                    launchError = error.localizedDescription
                }
            }
            return
        }

        programLaunching.insert(url)
        Telemetry.capture(.firstProgramLaunchAttempted)
        let useTerminal = NSEvent.modifierFlags.contains(.shift)
        Task {
            let result = await program.launchWithUserMode(useTerminal: useTerminal)
            programLaunching.remove(url)
            toast = result.toastData
        }
    }

    /// The orchestrator for a bottle, made once and kept.
    ///
    /// Its `phases` and `runningAppIds` are what the cards read, so it has to
    /// outlive the launch that created it.
    private func orchestrator(for bottle: Bottle) -> SteamClientOrchestrator {
        if let existing = orchestrators[bottle.url] {
            return existing
        }

        let made = SteamClientOrchestrator(bottle: bottle, driver: AppSteamClientDriver(bottle: bottle))
        let url = bottle.url
        made.$phases
            .sink { [weak self] phases in
                self?.steamLaunching[url] = Set(phases.keys)
            }
            .store(in: &cancellables)
        made.$runningAppIds
            .sink { [weak self] running in
                self?.steamRunning[url] = running
            }
            .store(in: &cancellables)
        made.$recordedSessions
            .dropFirst()
            .sink { [weak self] _ in
                self?.refreshPlayStats()
            }
            .store(in: &cancellables)
        made.$launchError
            .compactMap { $0 }
            .sink { [weak self] error in
                self?.launchError = error
            }
            .store(in: &cancellables)

        orchestrators[bottle.url] = made
        return made
    }

    /// Starts (or restarts) running-state polling for a bottle's Steam games.
    private func trackSteam(in bottle: Bottle) {
        let games = SteamLibrary.enumerate(bottleURL: bottle.url)
        guard !games.isEmpty else { return }
        orchestrator(for: bottle).startTracking(games: games)
    }

    /// Stops every poller. Called when the library leaves the screen.
    func stopTracking() {
        for orchestrator in orchestrators.values {
            orchestrator.stop()
        }
    }
}
