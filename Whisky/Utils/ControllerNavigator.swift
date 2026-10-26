//
//  ControllerNavigator.swift
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
import GameController

/// A keyboard event a controller input stands for.
struct ControllerKeyStroke: Equatable, Sendable {
    let keyCode: UInt16
    let characters: String
    let charactersIgnoringModifiers: String?
    /// Stored raw so the strokes can be static constants under strict
    /// concurrency without relying on how the SDK annotates the option set.
    private let modifierFlags: UInt

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }

    init(
        keyCode: UInt16,
        characters: String,
        charactersIgnoringModifiers: String? = nil,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        self.keyCode = keyCode
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.modifierFlags = modifiers.rawValue
    }

    static let space = ControllerKeyStroke(keyCode: 49, characters: " ")
    static let returnKey = ControllerKeyStroke(keyCode: 36, characters: "\r")
    static let escape = ControllerKeyStroke(keyCode: 53, characters: "\u{1B}")
    static let tab = ControllerKeyStroke(keyCode: 48, characters: "\t")
    static let backTab = ControllerKeyStroke(
        keyCode: 48, characters: "\u{19}", charactersIgnoringModifiers: "\t", modifiers: .shift
    )
    static let arrowUp = arrow(126, "\u{F700}")
    static let arrowDown = arrow(125, "\u{F701}")
    static let arrowLeft = arrow(123, "\u{F702}")
    static let arrowRight = arrow(124, "\u{F703}")
    static let pageUp = ControllerKeyStroke(keyCode: 116, characters: "\u{F72C}", modifiers: .function)
    static let pageDown = ControllerKeyStroke(keyCode: 121, characters: "\u{F72D}", modifiers: .function)
    static let back = ControllerKeyStroke(keyCode: 33, characters: "[", modifiers: .command)
    static let search = ControllerKeyStroke(keyCode: 3, characters: "f", modifiers: .command)
    static let settings = ControllerKeyStroke(keyCode: 43, characters: ",", modifiers: .command)
    static let toggleSidebar = ControllerKeyStroke(keyCode: 1, characters: "s", modifiers: [.command, .control])

    /// Arrow keys carry the function and keypad flags a real keyboard sets;
    /// AppKit's list and table views check for them.
    private static func arrow(_ keyCode: UInt16, _ character: String) -> ControllerKeyStroke {
        ControllerKeyStroke(keyCode: keyCode, characters: character, modifiers: [.function, .numericPad])
    }
}

/// The controller's buttons, by their Xbox-layout position.
enum ControllerButton: CaseIterable {
    case buttonA, buttonB, buttonX, buttonY
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case menu, view

    /// What pressing it does. Kept as a table rather than spread through the
    /// handler so the hint bar and the docs can read the same mapping.
    ///
    /// B is resolved at press time, see ``ControllerNavigator``.
    var stroke: ControllerKeyStroke {
        switch self {
        case .buttonA: .space
        case .buttonB: .escape
        case .buttonX: .returnKey
        case .buttonY: .toggleSidebar
        case .leftShoulder: .backTab
        case .rightShoulder: .tab
        case .leftTrigger: .pageUp
        case .rightTrigger: .pageDown
        case .menu: .settings
        case .view: .search
        }
    }

    func input(in gamepad: GCExtendedGamepad) -> GCControllerButtonInput? {
        switch self {
        case .buttonA: gamepad.buttonA
        case .buttonB: gamepad.buttonB
        case .buttonX: gamepad.buttonX
        case .buttonY: gamepad.buttonY
        case .leftShoulder: gamepad.leftShoulder
        case .rightShoulder: gamepad.rightShoulder
        case .leftTrigger: gamepad.leftTrigger
        case .rightTrigger: gamepad.rightTrigger
        case .menu: gamepad.buttonMenu
        case .view: gamepad.buttonOptions
        }
    }
}

/// Lets the whole app be driven from a game controller.
///
/// Rather than teaching every screen about controllers, inputs become the key
/// events macOS keyboard navigation already understands: the shoulders move
/// focus like Tab, A presses the focused control like Space, B closes a sheet
/// or goes back. Any screen that works from the keyboard therefore works from
/// a controller, and the screens that need more (the library grid's
/// directional movement) handle it the keyboard way too.
///
/// GameController only delivers input to the frontmost app, and the handler
/// also checks that Whisky is active, so a controller never drives the app
/// while a game has focus.
@MainActor
final class ControllerNavigator: ObservableObject {
    static let shared = ControllerNavigator()
    static let enabledKey = "controllerNavigation"

    /// Below this a stick counts as centred. High enough that a worn stick
    /// resting slightly off centre does not drift the focus.
    static let stickDeadzone: Float = 0.5
    static let repeatDelay: Duration = .milliseconds(350)
    static let repeatInterval: Duration = .milliseconds(90)

    /// The controller in use, for the hint bar's glyphs.
    @Published private(set) var controller: GCController?
    /// When the controller was last used. The hint bar shows for a while after.
    @Published private(set) var lastInput: Date?

    private var observers: [NSObjectProtocol] = []
    private var pressed: Set<ControllerButton> = []
    private var heldDirection: ControllerKeyStroke?
    private var repeatTask: Task<Void, Never>?
    private var scrollTask: Task<Void, Never>?
    private var scrollSpeed: CGFloat = 0

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private init() {}

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidBecomeCurrent, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attach(GCController.current) }
            })
        }
        attach(GCController.current)
    }

    private func attach(_ controller: GCController?) {
        self.controller = controller
        pressed.removeAll()
        stopRepeat()
        scrollSpeed = 0
        guard let controller, let gamepad = controller.extendedGamepad else { return }
        controller.handlerQueue = .main
        gamepad.valueChangedHandler = { [weak self] gamepad, _ in
            MainActor.assumeIsolated { self?.handle(gamepad) }
        }
    }

    // MARK: - Input

    private func handle(_ gamepad: GCExtendedGamepad) {
        guard isEnabled, NSApp.isActive else {
            pressed.removeAll()
            stopRepeat()
            scrollSpeed = 0
            return
        }

        // Edge-detected, because the handler fires for every analog change and
        // a trigger pulled slowly would otherwise press many times.
        for button in ControllerButton.allCases {
            guard let input = button.input(in: gamepad) else { continue }
            if input.isPressed, !pressed.contains(button) {
                pressed.insert(button)
                lastInput = Date()
                press(button)
            } else if !input.isPressed {
                pressed.remove(button)
            }
        }

        let direction = Self.direction(dpad: gamepad.dpad, stick: gamepad.leftThumbstick)
        if direction != heldDirection {
            stopRepeat()
            heldDirection = direction
            if let direction {
                lastInput = Date()
                startRepeat(direction)
            }
        }

        let scroll = CGFloat(gamepad.rightThumbstick.yAxis.value)
        scrollSpeed = abs(scroll) > 0.15 ? scroll : 0
        if scrollSpeed != 0 {
            lastInput = Date()
            startScrolling()
        }
    }

    /// The D-pad wins over the stick, and the stick's larger axis wins, so a
    /// diagonal moves one way instead of alternating.
    static func direction(dpad: GCControllerDirectionPad, stick: GCControllerDirectionPad) -> ControllerKeyStroke? {
        if dpad.up.isPressed { return .arrowUp }
        if dpad.down.isPressed { return .arrowDown }
        if dpad.left.isPressed { return .arrowLeft }
        if dpad.right.isPressed { return .arrowRight }
        return direction(horizontal: stick.xAxis.value, vertical: stick.yAxis.value)
    }

    static func direction(horizontal: Float, vertical: Float) -> ControllerKeyStroke? {
        guard max(abs(horizontal), abs(vertical)) >= stickDeadzone else { return nil }
        if abs(vertical) >= abs(horizontal) {
            return vertical > 0 ? .arrowUp : .arrowDown
        }
        return horizontal > 0 ? .arrowRight : .arrowLeft
    }

    private func press(_ button: ControllerButton) {
        if button == .buttonB {
            send(backStroke())
        } else {
            send(button.stroke)
        }
    }

    /// Escape closes a sheet, a menu or a search field, but does nothing to a
    /// navigation stack, which goes back on Command-[. B means "back" in every
    /// one of those, so it picks whichever the current context understands.
    private func backStroke() -> ControllerKeyStroke {
        guard let window = NSApp.keyWindow else { return .escape }
        if window.isSheet || window.attachedSheet != nil || NSApp.modalWindow != nil {
            return .escape
        }
        if window.firstResponder is NSText {
            return .escape
        }
        return .back
    }

    private func startRepeat(_ stroke: ControllerKeyStroke) {
        send(stroke)
        repeatTask = Task { [weak self] in
            try? await Task.sleep(for: Self.repeatDelay)
            while !Task.isCancelled {
                self?.send(stroke)
                try? await Task.sleep(for: Self.repeatInterval)
            }
        }
    }

    private func stopRepeat() {
        repeatTask?.cancel()
        repeatTask = nil
        heldDirection = nil
    }

    // MARK: - Output

    private func send(_ stroke: ControllerKeyStroke) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: stroke.modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: stroke.characters,
                charactersIgnoringModifiers: stroke.charactersIgnoringModifiers ?? stroke.characters,
                isARepeat: false,
                keyCode: stroke.keyCode
            ) else { continue }
            // Through the application rather than the window, so Command
            // shortcuts reach the main menu the way a real key press does.
            NSApp.sendEvent(event)
        }
    }

    /// Scrolls at a speed set by how far the right stick is pushed, for as long
    /// as it is held.
    private func startScrolling() {
        guard scrollTask == nil else { return }
        scrollTask = Task { [weak self] in
            while let self, !Task.isCancelled, scrollSpeed != 0 {
                scroll(by: -scrollSpeed * 18)
                try? await Task.sleep(for: .milliseconds(16))
            }
            self?.scrollTask = nil
        }
    }

    /// The scroll view around the focused control, or failing that the one in
    /// the middle of the window.
    private func scroll(by delta: CGFloat) {
        guard let window = NSApp.keyWindow, let content = window.contentView else { return }
        let focused = (window.firstResponder as? NSView)?.enclosingScrollView
        let center = NSPoint(x: content.bounds.midX, y: content.bounds.midY)
        guard let scrollView = focused ?? content.hitTest(center)?.enclosingScrollView,
              let document = scrollView.documentView
        else { return }

        let clip = scrollView.contentView
        let maxY = max(0, document.frame.height - clip.bounds.height)
        var origin = clip.bounds.origin
        origin.y += document.isFlipped ? delta : -delta
        origin.y = min(max(origin.y, 0), maxY)
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }
}
