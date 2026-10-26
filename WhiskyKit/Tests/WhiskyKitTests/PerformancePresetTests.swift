//
//  PerformancePresetTests.swift
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

final class PerformancePresetTests: XCTestCase {
    func testPerformancePresetSetsFastPaths() {
        var overrides = ProgramOverrides()
        PerformancePreset.performance.apply(to: &overrides)

        XCTAssertEqual(overrides.enhancedSync, .msync)
        XCTAssertEqual(overrides.dxvkAsync, true)
        XCTAssertEqual(overrides.shaderCacheEnabled, true)
        XCTAssertNil(overrides.metal4Enabled)
    }

    func testCompatibilityPresetSetsSafePaths() {
        var overrides = ProgramOverrides()
        PerformancePreset.compatibility.apply(to: &overrides)

        XCTAssertEqual(overrides.enhancedSync, .esync)
        XCTAssertEqual(overrides.dxvkAsync, false)
        XCTAssertEqual(overrides.metal4Enabled, false)
    }

    func testBalancedClearsOnlyWhatPresetsOwn() {
        var overrides = ProgramOverrides()
        overrides.graphicsBackend = .dxmt
        overrides.metalHud = true
        PerformancePreset.performance.apply(to: &overrides)
        PerformancePreset.balanced.apply(to: &overrides)

        XCTAssertNil(overrides.enhancedSync)
        XCTAssertNil(overrides.dxvkAsync)
        XCTAssertNil(overrides.shaderCacheEnabled)
        XCTAssertEqual(overrides.graphicsBackend, .dxmt)
        XCTAssertEqual(overrides.metalHud, true)
    }

    func testMatchingRecognisesEachPreset() {
        XCTAssertEqual(PerformancePreset.matching(nil), .balanced)
        for preset in PerformancePreset.allCases {
            var overrides = ProgramOverrides()
            preset.apply(to: &overrides)
            XCTAssertEqual(PerformancePreset.matching(overrides), preset)
        }
    }

    func testHandEditedSettingsMatchNoPreset() {
        var overrides = ProgramOverrides()
        PerformancePreset.performance.apply(to: &overrides)
        overrides.dxvkAsync = false

        XCTAssertNil(PerformancePreset.matching(overrides))
    }

    // MARK: - Per-program Metal HUD

    private func resolvedEnvironment(bottleHud: Bool, _ overrides: ProgramOverrides) -> [String: String] {
        var settings = BottleSettings()
        settings.metalHud = bottleHud
        var builder = EnvironmentBuilder()
        var dllResolver = DLLOverrideResolver(managed: [], bottleCustom: [], programCustom: [])

        _ = settings.populateBottleManagedLayer(builder: &builder)
        Wine.applyProgramOverrides(overrides, builder: &builder, dllResolver: &dllResolver)

        return builder.resolve().environment
    }

    func testProgramCanTurnOnMetalHudAlone() {
        var overrides = ProgramOverrides()
        overrides.metalHud = true

        XCTAssertEqual(resolvedEnvironment(bottleHud: false, overrides)["MTL_HUD_ENABLED"], "1")
        XCTAssertFalse(overrides.isEmpty)
    }

    func testProgramCanTurnOffBottleMetalHud() {
        var overrides = ProgramOverrides()
        overrides.metalHud = false

        XCTAssertNil(resolvedEnvironment(bottleHud: true, overrides)["MTL_HUD_ENABLED"])
    }

    func testMetalHudUnsetInheritsTheBottle() {
        XCTAssertEqual(resolvedEnvironment(bottleHud: true, ProgramOverrides())["MTL_HUD_ENABLED"], "1")
    }

    func testMetalHudSurvivesARoundTrip() throws {
        var overrides = ProgramOverrides()
        overrides.metalHud = true
        let data = try PropertyListEncoder().encode(overrides)
        let decoded = try PropertyListDecoder().decode(ProgramOverrides.self, from: data)
        XCTAssertEqual(decoded.metalHud, true)
    }
}
