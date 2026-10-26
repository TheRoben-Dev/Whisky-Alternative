//
//  PerformancePresetSection.swift
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

/// One-tap tuning for a program: a performance profile and the Metal HUD.
///
/// Both write ordinary program overrides, so whatever a preset sets shows up
/// in the overrides section below and can still be changed one by one.
struct PerformancePresetSection: View {
    @ObservedObject var program: Program

    private var preset: Binding<PerformancePreset?> {
        Binding(
            get: { PerformancePreset.matching(program.settings.overrides) },
            set: { newValue in
                guard let newValue else { return }
                update { newValue.apply(to: &$0) }
            }
        )
    }

    private var metalHud: Binding<Bool> {
        Binding(
            get: { program.settings.overrides?.metalHud ?? program.bottle.settings.metalHud },
            set: { newValue in update { $0.metalHud = newValue } }
        )
    }

    var body: some View {
        Section("program.performance.title") {
            Picker("program.performance.preset", selection: preset) {
                ForEach(PerformancePreset.allCases) { option in
                    Text(label(for: option)).tag(Optional(option))
                }
                if preset.wrappedValue == nil {
                    Text("program.performance.custom").tag(PerformancePreset?.none)
                }
            }
            .pickerStyle(.segmented)
            Text(description(for: preset.wrappedValue))
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("program.performance.metalHud", isOn: metalHud)
                .help("program.performance.metalHud.help")
        }
    }

    /// Edits the overrides in place, and drops them altogether once nothing is
    /// left overridden so the program goes back to plainly inheriting.
    private func update(_ change: (inout ProgramOverrides) -> Void) {
        var overrides = program.settings.overrides ?? ProgramOverrides()
        change(&overrides)
        program.settings.overrides = overrides.isEmpty && overrides.taggedVerbs == nil ? nil : overrides
    }

    private func label(for preset: PerformancePreset) -> LocalizedStringKey {
        switch preset {
        case .balanced: "program.performance.balanced"
        case .performance: "program.performance.performance"
        case .compatibility: "program.performance.compatibility"
        }
    }

    private func description(for preset: PerformancePreset?) -> LocalizedStringKey {
        switch preset {
        case .balanced: "program.performance.balanced.description"
        case .performance: "program.performance.performance.description"
        case .compatibility: "program.performance.compatibility.description"
        case nil: "program.performance.custom.description"
        }
    }
}
