//
//  LibraryCoverTests.swift
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

import Foundation
import Testing
@testable import WhiskyKit

@Suite("Library Cover Tests")
struct LibraryCoverTests {
    private func temporaryFolder() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entry(in bottleURL: URL, launch: LibraryEntry.Launch) -> LibraryEntry {
        LibraryEntry(id: "test", name: "Game", iconURL: nil, bottleURL: bottleURL, source: .pinned, launch: launch)
    }

    @Test("A cover is only ever the portrait capsule, never a cropped banner")
    func steamCoverIsPortraitOnly() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "appcache").appending(path: "librarycache").appending(path: "12345")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try Data().write(to: folder.appending(path: "header.jpg"))
        #expect(SteamLibrarySource.coverURL(appID: 12_345, steamRoot: root) == nil)

        try Data().write(to: folder.appending(path: "library_600x900.jpg"))
        #expect(SteamLibrarySource.coverURL(appID: 12_345, steamRoot: root)?.lastPathComponent
            == "library_600x900.jpg")

        // The 2x capsule is the sharper one on a Retina screen, so it wins.
        try Data().write(to: folder.appending(path: "library_600x900_2x.jpg"))
        #expect(SteamLibrarySource.coverURL(appID: 12_345, steamRoot: root)?.lastPathComponent
            == "library_600x900_2x.jpg")

        // The wide card art is unchanged by the cover lookup.
        #expect(SteamLibrarySource.artworkURL(appID: 12_345, steamRoot: root)?.lastPathComponent == "header.jpg")
    }

    @Test("A custom cover is stored in the bottle and laid over the source's own")
    func customCoverRoundTrip() throws {
        let bottle = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: bottle) }
        let image = bottle.appending(path: "picked.png")
        try Data([1, 2, 3]).write(to: image)
        let game = entry(in: bottle, launch: .program(bottle.appending(path: "drive_c/Game/Game.exe")))

        #expect(LibraryCoverStore.customCoverURL(for: game) == nil)

        let stored = try LibraryCoverStore.setCustomCover(from: image, for: game)
        #expect(stored.lastPathComponent == "program-Game.exe.png")
        #expect(LibraryCoverStore.customCoverURL(for: game) == stored)
        #expect(LibraryCoverStore.applyingCustomCovers(to: [game]).first?.coverURL == stored)

        LibraryCoverStore.removeCustomCover(for: game)
        #expect(LibraryCoverStore.customCoverURL(for: game) == nil)
        #expect(LibraryCoverStore.applyingCustomCovers(to: [game]).first?.coverURL == nil)
    }

    @Test("Replacing a cover with another format leaves only the new one")
    func replacingChangesFormatCleanly() throws {
        let bottle = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: bottle) }
        let png = bottle.appending(path: "a.png")
        let jpg = bottle.appending(path: "b.jpg")
        try Data([1]).write(to: png)
        try Data([2]).write(to: jpg)
        let game = entry(in: bottle, launch: .steam(appID: 42))

        try LibraryCoverStore.setCustomCover(from: png, for: game)
        let replaced = try LibraryCoverStore.setCustomCover(from: jpg, for: game)

        let folder = LibraryCoverStore.folder(in: bottle)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        #expect(files == ["steam-42.jpg"])
        #expect(LibraryCoverStore.customCoverURL(for: game) == replaced)
    }

    @Test("Something that is not an image is refused")
    func refusesNonImages() throws {
        let bottle = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: bottle) }
        let text = bottle.appending(path: "notes.txt")
        try Data().write(to: text)

        #expect(throws: (any Error).self) {
            try LibraryCoverStore.setCustomCover(from: text, for: entry(in: bottle, launch: .steam(appID: 1)))
        }
    }
}
