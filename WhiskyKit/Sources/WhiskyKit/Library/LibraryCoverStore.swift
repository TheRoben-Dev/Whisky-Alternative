//
//  LibraryCoverStore.swift
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

/// Covers the person picked for library entries, kept inside the bottle.
///
/// Inside the bottle rather than in Application Support so a cover travels
/// with the bottle when it is exported or moved, the same as its program
/// settings do. One file per entry, named by what launches it rather than by
/// the entry's id: the id carries the bottle's path, which changes when the
/// bottle moves, and the cover should not get lost when it does.
public enum LibraryCoverStore {
    /// The image types a cover can be. The copy keeps the original's
    /// extension, so nothing is re-encoded and a PNG with transparency stays one.
    public static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "webp", "avif", "gif", "tiff", "bmp"
    ]

    static func folder(in bottleURL: URL) -> URL {
        bottleURL.appending(path: "Library Covers")
    }

    /// A filesystem-safe name for what `entry` launches.
    static func key(for entry: LibraryEntry) -> String {
        switch entry.launch {
        case let .program(url):
            "program-" + url.lastPathComponent.replacingOccurrences(of: "/", with: "_")
        case let .steam(appID):
            "steam-\(appID)"
        }
    }

    /// The cover the person chose for `entry`, if they chose one.
    public static func customCoverURL(for entry: LibraryEntry) -> URL? {
        let key = key(for: entry)
        let contents = try? FileManager.default.contentsOfDirectory(
            at: folder(in: entry.bottleURL), includingPropertiesForKeys: nil
        )
        return contents?.first { $0.deletingPathExtension().lastPathComponent == key }
    }

    /// Copies the image at `source` in as `entry`'s cover, replacing any
    /// earlier one.
    ///
    /// - Returns: Where the cover now lives.
    @discardableResult
    public static func setCustomCover(from source: URL, for entry: LibraryEntry) throws -> URL {
        let ext = source.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let folder = folder(in: entry.bottleURL)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A different extension would leave the old cover next to the new one,
        // and then which one shows depends on directory order.
        removeCustomCover(for: entry)
        let destination = folder.appending(path: key(for: entry)).appendingPathExtension(ext)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// Goes back to whatever cover the entry's source provides.
    public static func removeCustomCover(for entry: LibraryEntry) {
        while let existing = customCoverURL(for: entry) {
            guard (try? FileManager.default.removeItem(at: existing)) != nil else { return }
        }
    }

    /// `entries` with each custom cover laid over the cover its source found.
    ///
    /// Each bottle's folder is listed once rather than once per entry, since
    /// this runs on every library reload.
    public static func applyingCustomCovers(to entries: [LibraryEntry]) -> [LibraryEntry] {
        var covers: [URL: [String: URL]] = [:]
        return entries.map { entry in
            if covers[entry.bottleURL] == nil {
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: folder(in: entry.bottleURL), includingPropertiesForKeys: nil
                )) ?? []
                covers[entry.bottleURL] = Dictionary(
                    contents.map { ($0.deletingPathExtension().lastPathComponent, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
            guard let custom = covers[entry.bottleURL]?[key(for: entry)] else { return entry }
            return entry.withCover(custom)
        }
    }
}
