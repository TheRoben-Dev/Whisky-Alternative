//
//  LibraryCoverCard.swift
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

/// One library entry as portrait box art, the way console launchers show a
/// library.
///
/// The cover is the one the person chose, or Steam's own 600x900 capsule. A
/// program with neither gets a poster drawn from its icon's colour, with the
/// icon and name on it, so the grid never shows a blank or stretched tile.
/// Dropping an image onto a cover makes it that entry's cover.
struct LibraryCoverCard: View {
    /// Box art is 2:3, which is what Steam, consoles and SteamGridDB all use.
    static let aspectRatio: CGFloat = 2 / 3

    let row: LibraryRow
    let state: LibraryEntryState
    let launch: () -> Void
    let setCover: (URL) -> Void
    /// Owned by the grid, which moves it between covers on arrow keys and the
    /// controller's D-pad.
    let focus: FocusState<String?>.Binding

    @State private var cover: Image?
    @State private var icon: Image?
    @State private var palette: IconPalette = .neutral
    @State private var isHovering = false
    @State private var isDropTargeted = false

    private var item: LibraryEntry { row.item }
    private var isFocused: Bool { focus.wrappedValue == item.id }
    private var isActive: Bool { isHovering || isFocused }
    private var title: String { item.launcher?.displayName ?? item.name }

    var body: some View {
        Button(action: launch) {
            VStack(alignment: .leading, spacing: 8) {
                poster
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
        .focusable()
        .focused(focus, equals: item.id)
        .focusEffectDisabled()
        .onKeyPress(.return) {
            launch()
            return .handled
        }
        // Space is how the controller's A button arrives.
        .onKeyPress(.space) {
            launch()
            return .handled
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { isHovering = hovering }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let image = urls.first(where: Self.isImage) else { return false }
            setCover(image)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .task(id: item.coverURL ?? item.iconURL) {
            await loadArt()
        }
        .accessibilityLabel(title)
        .accessibilityValue(Text(subtitle))
        .accessibilityHint(Text("library.card.hint"))
    }

    private var poster: some View {
        Color.clear
            .aspectRatio(Self.aspectRatio, contentMode: .fit)
            .overlay {
                if let cover {
                    cover
                        .resizable()
                        .scaledToFill()
                } else {
                    drawnPoster
                }
            }
            .overlay(alignment: .topTrailing) {
                statusBadge
                    .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isFocused || isDropTargeted ? 3 : 1)
            }
            // On a controller the glow is the only cue for where you are, so it
            // is stronger than the hover lift.
            .shadow(
                color: isFocused ? Color.accentColor.opacity(0.55) : .black.opacity(isActive ? 0.35 : 0.22),
                radius: isFocused ? 18 : (isActive ? 12 : 6),
                y: isFocused ? 0 : 4
            )
            .scaleEffect(isFocused ? 1.05 : (isActive ? 1.02 : 1))
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    private var borderColor: Color {
        if isFocused || isDropTargeted { return .accentColor }
        return .white.opacity(isActive ? 0.22 : 0.08)
    }

    /// Stands in for box art: the icon's colour as a deep wash, the icon large,
    /// and the name set like a title on the cover.
    private var drawnPoster: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color(palette.deepened(toLuminance: 0.32)), Color(palette.deepened(toLuminance: 0.05))],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack {
                Spacer()
                if let icon {
                    icon
                        .resizable()
                        .frame(width: 72, height: 72)
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                }
                Spacer()
                Spacer()
            }
            .frame(maxWidth: .infinity)
            Text(title)
                .font(.headline)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.white)
                .padding(12)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch state {
        case .launching:
            ProgressView()
                .controlSize(.small)
                .padding(6)
                .background(.ultraThinMaterial, in: Circle())
                .help("library.card.launching")
        case .running:
            Label("library.card.running", systemImage: "circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .imageScale(.small)
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
        case .idle:
            if isActive {
                Image(systemName: "play.fill")
                    .font(.system(size: 13))
                    .frame(width: 30, height: 30)
                    .background(.ultraThinMaterial, in: Circle())
                    .transition(.opacity.combined(with: .scale))
            }
        }
    }

    /// Playtime first, because on a cover grid it is the number people compare;
    /// last played when there is none yet.
    private var subtitle: String {
        var parts: [String] = []
        if row.playtime > 0 {
            parts.append(PlayStatsFormat.duration(row.playtime))
        } else if let lastPlayed = row.lastPlayed {
            parts.append(lastPlayed.formatted(.relative(presentation: .named)))
        } else if item.isLauncher {
            parts.append(String(localized: "library.card.launcher"))
        } else {
            parts.append(String(localized: "library.card.neverRun"))
        }
        if let bottleName = row.bottleName {
            parts.append(bottleName)
        }
        return parts.joined(separator: " · ")
    }

    private func loadArt() async {
        if let coverURL = item.coverURL,
           let sampled = await IconCache.shared.sampledArtwork(for: coverURL) {
            cover = Image(nsImage: sampled.image)
            palette = sampled.palette
            return
        }
        cover = nil
        guard let iconURL = item.iconURL else {
            palette = .neutral
            icon = nil
            return
        }
        let sampled = await IconCache.shared.sampledIcon(for: iconURL)
        palette = sampled.palette
        icon = Image(nsImage: sampled.image)
    }

    static func isImage(_ url: URL) -> Bool {
        LibraryCoverStore.supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
