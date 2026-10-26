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

    @StateObject private var model = LibraryModel()
    @State private var search: String = ""
    @FocusState private var focusedRow: String?
    @State private var gridWidth: CGFloat = 0

    /// Must match the grid's `GridItem` and padding below, so arrow movement
    /// lands on the card that is visually above or below.
    private static let cardMinWidth: CGFloat = 180
    private static let cardSpacing: CGFloat = 14
    private static let gridPadding: CGFloat = 18

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

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    // 180 rather than 220 so two columns fit at the window's own
                    // minimum width, where the sidebar leaves about 330pt: one
                    // column of landscape cards is a list with wasted space.
                    columns: [
                        GridItem(.adaptive(minimum: Self.cardMinWidth, maximum: 320), spacing: Self.cardSpacing)
                    ],
                    spacing: Self.cardSpacing
                ) {
                    ForEach(visible) { row in
                        LibraryCard(
                            item: row.item,
                            bottleName: row.bottleName,
                            lastPlayed: row.lastPlayed,
                            playtime: row.playtime,
                            state: model.state(for: row.item),
                            launch: { model.launch(row, bottles: bottles) },
                            focus: $focusedRow
                        )
                        .contextMenu { menu(for: row) }
                    }
                }
                .padding(Self.gridPadding)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            .onMoveCommand(perform: moveFocus)
            .onChange(of: focusedRow) {
                guard let focusedRow else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(focusedRow) }
            }
        }
    }

    /// How many cards the adaptive grid fits in a row at the current width.
    private var columnCount: Int {
        let available = gridWidth - Self.gridPadding * 2
        return max(1, Int((available + Self.cardSpacing) / (Self.cardMinWidth + Self.cardSpacing)))
    }

    /// Moves focus to the card in that direction. The grid needs this because
    /// macOS only moves focus between controls with Tab: arrow keys, and the
    /// controller's D-pad that sends them, would otherwise do nothing here.
    private func moveFocus(_ direction: MoveCommandDirection) {
        let ids = visible.map(\.id)
        guard let first = ids.first else { return }
        guard let current = focusedRow, let index = ids.firstIndex(of: current) else {
            focusedRow = first
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
        }
    }

    @ViewBuilder
    private func menu(for row: LibraryRow) -> some View {
        Button("button.run") { model.launch(row, bottles: bottles) }
        if model.state(for: row.item) == .running {
            Button("library.card.stop") { model.stop(row, bottles: bottles) }
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
