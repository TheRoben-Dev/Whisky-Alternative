//
//  LibraryView.swift
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
import SwiftUI
import UniformTypeIdentifiers
import WhiskyKit

/// Everything worth launching, across every bottle, most recently played first.
///
/// This is the home screen because it is the thing people open Whisky to do. A
/// bottle is a Wine prefix, which is an implementation detail of running a
/// Windows program on a Mac, and it only earns space on screen once there is
/// more than one of them.
///
/// Entries come from ``LibraryCatalogue``, so Steam games sit beside pinned
/// programs and a future launcher needs no change here.
struct LibraryView: View {
    @EnvironmentObject var bottleVM: BottleVM
    @Binding var selectedBottle: URL?
    /// Toggled by the toolbar's refresh button. Folded into the reload trigger
    /// because the bottle list is unchanged by a refresh, so watching only that
    /// left the button spinning without rebuilding anything.
    @Binding var refresh: Bool

    @AppStorage("librarySort") private var sort: LibrarySort = .recent
    @AppStorage("libraryLayout") private var layout: LibraryLayout = .covers

    @StateObject private var model = LibraryModel()
    @State private var search: String = ""
    @FocusState private var focusedRow: String?
    @State private var gridWidth: CGFloat = 0

    /// Must match the grid's `GridItem` and padding below, so arrow movement
    /// lands on the card that is visually above or below.
    private static let wideCardSpacing: CGFloat = 14
    private static let gridPadding: CGFloat = 18

    /// 180 for wide cards so two columns fit at the window's own minimum width,
    /// where the sidebar leaves about 330pt. Covers are narrower, since a 2:3
    /// poster at 180pt wide is already taller than a screen row of cards.
    private var cardMinWidth: CGFloat { layout == .covers ? 140 : 180 }
    private var cardMaxWidth: CGFloat { layout == .covers ? 220 : 320 }
    private var cardSpacing: CGFloat { layout == .covers ? 20 : Self.wideCardSpacing }

    private var bottles: [Bottle] { bottleVM.bottles.filter(\.isAvailable) }

    private var visible: [LibraryRow] {
        guard !search.isEmpty else { return model.rows }
        return model.rows.filter { $0.item.name.localizedCaseInsensitiveContains(search) }
    }

    /// Every input that changes what the grid should contain. Pins live in
    /// bottle settings, so a program pinned in the bottle screen shows up here
    /// without a relaunch.
    private var reloadTrigger: String {
        let pins = bottles.flatMap { $0.settings.pins.map(\.name) }
        return (bottles.map(\.url.path) + pins + ["\(refresh)"]).joined(separator: "\u{1F}")
    }

    var body: some View {
        Group {
            if model.rows.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .navigationTitle("library.title")
        .searchable(text: $search, prompt: Text("library.search"))
        .toolbar { sortMenu }
        .toast($model.toast)
        .task(id: reloadTrigger) {
            await model.reload(bottles: bottles)
        }
        .onChange(of: sort, initial: true) {
            model.sort = sort
        }
        .onDisappear {
            model.stopTracking()
        }
        .alert(
            "library.launch.failed",
            isPresented: Binding(
                get: { model.launchError != nil },
                set: { if !$0 { model.launchError = nil } }
            )
        ) {
            Button("button.ok") { model.launchError = nil }
        } message: {
            Text(model.launchError ?? "")
        }
    }

    private var sortMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("library.layout", selection: $layout) {
                    ForEach(LibraryLayout.allCases) { option in
                        Label {
                            Text(option.label)
                        } icon: {
                            Image(systemName: option.systemImage)
                        }
                        .tag(option)
                    }
                }
                .pickerStyle(.inline)
                Picker("library.sort", selection: $sort) {
                    ForEach(LibrarySort.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("library.sort", systemImage: "arrow.up.arrow.down")
            }
            .accessibilityIdentifier("library.sort")
        }
    }

    /// The game the banner offers to continue: the most recently played one
    /// that is not a launcher. Hidden while searching, where the banner would
    /// push the matches down for something that may not be one of them.
    private var heroRow: LibraryRow? {
        guard search.isEmpty else { return nil }
        return model.rows
            .filter { !$0.item.isLauncher && $0.lastPlayed != nil }
            .max { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let hero = heroRow {
                        LibraryHero(
                            row: hero,
                            state: model.state(for: hero.item),
                            launch: { model.launch(hero, bottles: bottles) },
                            focus: $focusedRow
                        )
                        .id(LibraryHero.focusID)
                        .contextMenu { menu(for: hero) }

                        Text("library.section.all")
                            .font(.title3.weight(.bold))
                            .padding(.top, 4)
                    }

                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: cardMinWidth, maximum: cardMaxWidth), spacing: cardSpacing)
                        ],
                        alignment: .leading,
                        spacing: layout == .covers ? 24 : cardSpacing
                    ) {
                        ForEach(visible) { row in
                            gridItem(for: row)
                                .contextMenu { menu(for: row) }
                        }
                    }
                }
                .padding(Self.gridPadding)
            }
            .background(LibraryBackdrop())
            // The library is the console-style part of the app, so it is dark
            // whatever the system appearance; settings and bottle pages are not.
            .environment(\.colorScheme, .dark)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            .onMoveCommand(perform: moveFocus)
            .onChange(of: focusedRow) {
                guard let focusedRow else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(focusedRow) }
            }
        }
    }

    @ViewBuilder
    private func gridItem(for row: LibraryRow) -> some View {
        switch layout {
        case .covers:
            LibraryCoverCard(
                row: row,
                state: model.state(for: row.item),
                launch: { model.launch(row, bottles: bottles) },
                setCover: { url in Task { await model.setCover(from: url, for: row, bottles: bottles) } },
                focus: $focusedRow
            )
        case .cards:
            LibraryCard(
                item: row.item,
                bottleName: row.bottleName,
                lastPlayed: row.lastPlayed,
                playtime: row.playtime,
                state: model.state(for: row.item),
                launch: { model.launch(row, bottles: bottles) },
                focus: $focusedRow
            )
        }
    }

    /// How many cards the adaptive grid fits in a row at the current width.
    private var columnCount: Int {
        let available = gridWidth - Self.gridPadding * 2
        return max(1, Int((available + cardSpacing) / (cardMinWidth + cardSpacing)))
    }

    /// Moves focus to the card in that direction. The grid needs this because
    /// macOS only moves focus between controls with Tab: arrow keys, and the
    /// controller's D-pad that sends them, would otherwise do nothing here.
    ///
    /// The banner sits above the first row: up from there reaches it, and down
    /// from it lands on the first card.
    private func moveFocus(_ direction: MoveCommandDirection) {
        let ids = visible.map(\.id)
        let hasHero = heroRow != nil

        if focusedRow == LibraryHero.focusID {
            if direction == .down, let first = ids.first {
                focusedRow = first
            }
            return
        }

        guard let current = focusedRow, let index = ids.firstIndex(of: current) else {
            focusedRow = hasHero ? LibraryHero.focusID : ids.first
            return
        }

        let target = switch direction {
        case .left: index - 1
        case .right: index + 1
        case .up: index - columnCount
        case .down: index + columnCount
        @unknown default: index
        }
        if ids.indices.contains(target) {
            focusedRow = ids[target]
        } else if direction == .up, hasHero {
            focusedRow = LibraryHero.focusID
        }
    }

    @ViewBuilder
    private func menu(for row: LibraryRow) -> some View {
        Button("button.run") { model.launch(row, bottles: bottles) }
        if model.state(for: row.item) == .running {
            Button("library.card.stop") { model.stop(row, bottles: bottles) }
        }
        Divider()
        Button("library.cover.choose") { chooseCover(for: row) }
        if LibraryCoverStore.customCoverURL(for: row.item) != nil {
            Button("library.cover.reset") {
                Task { await model.resetCover(for: row, bottles: bottles) }
            }
        }
        Divider()
        if case let .program(url) = row.item.launch {
            Button("button.showInFinder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button("library.card.unpin", role: .destructive) { unpin(url, in: row.item.bottleURL) }
        }
        // Per-program settings live inside the bottle's own navigation stack,
        // which the library cannot push onto, so this is as close as the menu
        // gets without a deep link into it.
        Button("library.card.configure") {
            selectedBottle = row.item.bottleURL
        }
    }

    /// Asks for an image to use as `row`'s cover.
    private func chooseCover(for row: LibraryRow) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "library.cover.panelMessage")
        panel.prompt = String(localized: "library.cover.choosePrompt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.setCover(from: url, for: row, bottles: bottles) }
    }

    private func unpin(_ url: URL, in bottleURL: URL) {
        guard let bottle = bottles.first(where: { $0.url == bottleURL }) else { return }
        bottle.settings.pins.removeAll { $0.url == url }
        if let program = bottle.programs.first(where: { $0.url == url }) {
            program.pinned = false
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("library.empty.title", systemImage: "square.grid.2x2")
        } description: {
            Text(bottles.isEmpty ? "library.empty.noBottle" : "library.empty.noPrograms")
        } actions: {
            if let first = bottles.first {
                Button("library.empty.pinHint") { selectedBottle = first.url }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// The library's dark backdrop: near black with a faint accent glow from the
/// top, so cards and their art carry the colour rather than the window.
struct LibraryBackdrop: View {
    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.055, blue: 0.07)
            RadialGradient(
                colors: [Color.accentColor.opacity(0.18), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}
