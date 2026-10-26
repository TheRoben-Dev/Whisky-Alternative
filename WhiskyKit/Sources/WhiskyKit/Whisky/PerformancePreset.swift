//
//  PerformancePreset.swift
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

/// A one-tap tuning profile for a program, written as ordinary
/// ``ProgramOverrides`` so the individual settings stay visible and editable
/// in the overrides section afterwards.
///
/// Only the settings a preset owns are touched: sync primitive, DXVK async
/// shader compilation, the shader cache and the Metal 4 submission path.
/// The graphics backend is deliberately left alone, because which translation
/// layer a game runs on is a compatibility question the GameDB answers per
/// title, not something a generic profile can know.
public enum PerformancePreset: String, CaseIterable, Identifiable, Sendable {
    /// Inherit everything from the bottle.
    case balanced
    /// MSync, async shader compilation and the shader cache: the fastest
    /// combination, at the cost of stutter-free shaders being compiled later.
    case performance
    /// ESync, synchronous shaders and no Metal 4 path: slower, but avoids the
    /// sync and submission paths behind most hangs.
    case compatibility

    public var id: String { rawValue }

    /// The values this preset gives the settings it owns. `nil` means inherit.
    private var values: Values {
        switch self {
        case .balanced:
            Values(enhancedSync: nil, dxvkAsync: nil, shaderCacheEnabled: nil, metal4Enabled: nil)
        case .performance:
            Values(enhancedSync: .msync, dxvkAsync: true, shaderCacheEnabled: true, metal4Enabled: nil)
        case .compatibility:
            Values(enhancedSync: .esync, dxvkAsync: false, shaderCacheEnabled: true, metal4Enabled: false)
        }
    }

    /// Writes this preset's settings into `overrides`, leaving everything it
    /// does not own as it was.
    public func apply(to overrides: inout ProgramOverrides) {
        let values = values
        overrides.enhancedSync = values.enhancedSync
        overrides.dxvkAsync = values.dxvkAsync
        overrides.shaderCacheEnabled = values.shaderCacheEnabled
        overrides.metal4Enabled = values.metal4Enabled
    }

    /// The preset `overrides` currently matches, or `nil` when the settings a
    /// preset owns have been changed by hand into something no preset sets.
    public static func matching(_ overrides: ProgramOverrides?) -> PerformancePreset? {
        let current = Values(
            enhancedSync: overrides?.enhancedSync,
            dxvkAsync: overrides?.dxvkAsync,
            shaderCacheEnabled: overrides?.shaderCacheEnabled,
            metal4Enabled: overrides?.metal4Enabled
        )
        return allCases.first { $0.values == current }
    }

    private struct Values: Equatable {
        let enhancedSync: EnhancedSync?
        let dxvkAsync: Bool?
        let shaderCacheEnabled: Bool?
        let metal4Enabled: Bool?
    }
}
