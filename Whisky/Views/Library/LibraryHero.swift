//
//  LibraryHero.swift
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

import SwiftUI
import WhiskyKit

/// The "continue playing" banner across the top of the library.
///
/// Console launchers lead with the last thing you played because that is what
/// most sessions start with; the grid below is for everything else. It shows
/// the game's own art when Steam cached some, and otherwise a wash of its icon's
/// colour with the icon large on top.
struct LibraryHero: View {
    /// Focus id the grid uses for the banner, so the D-pad can move up into it
    /// from the first row of cards.
    static let focusID = "library.hero"

    let row: LibraryRow
    let state: LibraryEntryState
    let launch: () -> Void
    let focus: FocusState<String?>.Binding

    @State private var artwork: Image?
    @State private var icon: Image?
    @State private var palette: IconPalette = .neutral

    private var isFocused: Bool { focus.wrappedValue == Self.focusID }
    private var title: String { row.item.launcher?.displayName ?? row.item.name }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            background
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )

            HStack(alignment: .bottom, spacing: 18) {
                if artwork == nil, let icon {
                    icon
                        .resizable()
                        .frame(width: 96, height: 96)
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("library.hero.continue")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(title)
                        .font(.system(size: 30, weight: .bold))
                        .lineLimit(1)
                    Text(details)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                playButton
            }
            .foregroundStyle(.white)
            .padding(24)
        }
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isFocused ? Color.accentColor : .white.opacity(0.08), lineWidth: isFocused ? 3 : 1)
        }
        .shadow(color: isFocused ? Color.accentColor.opacity(0.45) : .black.opacity(0.25), radius: isFocused ? 18 : 8)
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .task(id: row.item.id) { await loadArt() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var background: some View {
        if let artwork {
            Color.clear
                .overlay {
                    artwork
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
        } else {
            LinearGradient(
                colors: [Color(palette.deepened(toLuminance: 0.3)), Color(palette.deepened(toLuminance: 0.06))],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var playButton: some View {
        Button(action: launch) {
            Label(
                state == .running ? LocalizedStringKey("library.card.running") : LocalizedStringKey("button.run"),
                systemImage: state == .running ? "circle.fill" : "play.fill"
            )
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(Color.accentColor, in: Capsule())
            .foregroundStyle(.white)
            .scaleEffect(isFocused ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .disabled(state == .launching)
        .focusable()
        .focused(focus, equals: Self.focusID)
        .focusEffectDisabled()
        .onKeyPress(.return) {
            launch()
            return .handled
        }
        .onKeyPress(.space) {
            launch()
            return .handled
        }
    }

    private var details: String {
        var parts: [String] = []
        if let lastPlayed = row.lastPlayed {
            parts.append(lastPlayed.formatted(.relative(presentation: .named)))
        }
        if row.playtime > 0 {
            parts.append(String(localized: "library.card.played \(PlayStatsFormat.duration(row.playtime))"))
        }
        if let bottleName = row.bottleName {
            parts.append(bottleName)
        }
        return parts.joined(separator: " · ")
    }

    private func loadArt() async {
        if let artworkURL = row.item.artworkURL,
           let sampled = await IconCache.shared.sampledArtwork(for: artworkURL) {
            artwork = Image(nsImage: sampled.image)
            palette = sampled.palette
            return
        }
        artwork = nil
        guard let iconURL = row.item.iconURL else {
            palette = .neutral
            icon = nil
            return
        }
        let sampled = await IconCache.shared.sampledIcon(for: iconURL)
        palette = sampled.palette
        icon = Image(nsImage: sampled.image)
    }
}
