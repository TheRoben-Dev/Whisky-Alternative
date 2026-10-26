//
//  ControllerHintBar.swift
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

import GameController
import SwiftUI

/// The console-style row of button prompts along the bottom of the window.
///
/// Shown only while the controller is in use and hidden a few seconds after
/// the last input, so somebody on the mouse is never looking at prompts for a
/// controller they put down an hour ago.
struct ControllerHintBar: View {
    @ObservedObject var navigator = ControllerNavigator.shared
    @AppStorage(ControllerNavigator.enabledKey) private var enabled = true
    @State private var isVisible = false

    private static let visibleFor: Duration = .seconds(8)

    private let hints: [(ControllerButton, LocalizedStringKey)] = [
        (.buttonA, "controller.hint.select"),
        (.buttonB, "controller.hint.back"),
        (.buttonX, "controller.hint.confirm"),
        (.buttonY, "controller.hint.sidebar"),
        (.view, "controller.hint.search"),
        (.menu, "controller.hint.settings")
    ]

    var body: some View {
        Group {
            if enabled, isVisible, let gamepad = navigator.controller?.extendedGamepad {
                HStack(spacing: 18) {
                    ForEach(hints.indices, id: \.self) { index in
                        hint(hints[index].0, hints[index].1, gamepad: gamepad)
                    }
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .hintBackground()
                .padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isVisible)
        .task(id: navigator.lastInput) {
            guard navigator.lastInput != nil else { return }
            isVisible = true
            try? await Task.sleep(for: Self.visibleFor)
            if !Task.isCancelled { isVisible = false }
        }
    }

    /// The glyph comes from the controller itself, so an Xbox pad shows A and
    /// B where they sit on that pad, and other pads show their own markings.
    private func hint(
        _ button: ControllerButton, _ label: LocalizedStringKey, gamepad: GCExtendedGamepad
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: button.input(in: gamepad)?.sfSymbolsName ?? "circle")
                .imageScale(.large)
            Text(label)
        }
    }
}

private extension View {
    @ViewBuilder
    func hintBackground() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }
}
