import AppKit
import ApplicationServices
import Foundation

/// macOS space (desktop) layout, as published by the Dock in com.apple.spaces.
///
/// There is no public API for Spaces, so the layout is read from the same plist
/// Mission Control reads, and desktops are switched with the "Switch to Desktop N"
/// keyboard shortcut after moving the pointer onto the target display.
struct SpaceLayout {
    /// "Main" or an uppercase display UUID -> ManagedSpaceIDs in desktop order.
    var spaces: [String: [Int]] = [:]
    /// "Main" or an uppercase display UUID -> currently shown ManagedSpaceID.
    var current: [String: Int] = [:]

    private func key(for display: DisplayInfo) -> String? {
        if spaces[display.uuid] != nil { return display.uuid }
        if display.isMain, spaces["Main"] != nil { return "Main" }
        return nil
    }

    func spaceIDs(for display: DisplayInfo) -> [Int]? {
        guard let key = key(for: display) else { return nil }
        return spaces[key]
    }

    func desktopCount(for display: DisplayInfo) -> Int? {
        spaceIDs(for: display)?.count
    }

    /// 1-based desktop number currently shown on this display.
    func currentDesktop(for display: DisplayInfo) -> Int? {
        guard let key = key(for: display),
              let ids = spaces[key],
              let currentID = current[key],
              let index = ids.firstIndex(of: currentID) else { return nil }
        return index + 1
    }
}

enum SpacesService {
    static func load() -> SpaceLayout? {
        loadFromWindowServer() ?? loadFromPreferences()
    }

    private static func loadFromWindowServer() -> SpaceLayout? {
        guard let displays = WindowServer.displaySpaces() else { return nil }
        var layout = SpaceLayout()
        for display in displays {
            guard let identifier = display["Display Identifier"] as? String else { continue }
            let key = identifier.uppercased()
            if let raw = display["Spaces"] as? [[String: Any]] {
                layout.spaces[key] = raw.compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.intValue }
            }
            if let current = display["Current Space"] as? [String: Any],
               let id = (current["ManagedSpaceID"] as? NSNumber)?.intValue {
                layout.current[key] = id
            }
        }
        return layout.spaces.isEmpty ? nil : layout
    }

    private static func loadFromPreferences() -> SpaceLayout? {
        let result = runProcess("/usr/bin/defaults", ["export", "com.apple.spaces", "-"])
        guard result.status == 0, let data = result.stdout.data(using: .utf8) else { return nil }
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = root as? [String: Any],
              let configuration = dictionary["SpacesDisplayConfiguration"] as? [String: Any],
              let management = configuration["Management Data"] as? [String: Any],
              let monitors = management["Monitors"] as? [[String: Any]] else {
            return nil
        }

        var layout = SpaceLayout()
        for monitor in monitors {
            guard let identifier = monitor["Display Identifier"] as? String else { continue }
            let key = identifier.caseInsensitiveCompare("Main") == .orderedSame ? "Main" : identifier.uppercased()

            if let rawSpaces = monitor["Spaces"] as? [[String: Any]] {
                let ids = rawSpaces.compactMap { space -> Int? in
                    (space["ManagedSpaceID"] as? NSNumber)?.intValue
                }
                layout.spaces[key] = ids
            }
            if let current = monitor["Current Space"] as? [String: Any],
               let id = (current["ManagedSpaceID"] as? NSNumber)?.intValue {
                layout.current[key] = id
            }
        }
        return layout
    }

    static func accessibilityEnabled(prompt: Bool) -> Bool {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    /// Reports which "Switch to Desktop N" (Ctrl+N) shortcuts are enabled.
    static func shortcutStatus() -> [Int: Bool] {
        let result = runProcess("/usr/bin/defaults", ["export", "com.apple.symbolichotkeys", "-"])
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = root as? [String: Any],
              let hotkeys = dictionary["AppleSymbolicHotKeys"] as? [String: Any] else {
            return [:]
        }

        var status: [Int: Bool] = [:]
        for desktop in 1...9 {
            let identifier = String(117 + desktop) // 118 = desktop 1 ... 126 = desktop 9
            guard let entry = hotkeys[identifier] as? [String: Any] else { continue }
            let enabled = (entry["enabled"] as? NSNumber)?.boolValue ?? false
            guard let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [NSNumber],
                  parameters.count >= 3 else {
                status[desktop] = false
                continue
            }
            let control = (parameters[2].intValue & 0x40000) != 0
            status[desktop] = enabled && control && parameters[1].intValue == Self.digitKeyCodes[desktop]
        }
        return status
    }

    private static let digitKeyCodes: [Int: Int] = [
        1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28, 9: 25,
    ]

    static func postControlDigit(_ desktop: Int) {
        guard let keyCode = digitKeyCodes[desktop] else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true)
        down?.flags = .maskControl
        down?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)
        up?.flags = .maskControl
        up?.post(tap: .cghidEventTap)
    }

    /// Moves the pointer onto `display`. Mission Control's space shortcuts act on the
    /// display under the pointer, so this is what makes multi-display switching work.
    static func aimPointer(at display: DisplayInfo) {
        CGWarpMouseCursorPosition(display.aimPoint)
        CGAssociateMouseAndMouseCursorPosition(1)
        Thread.sleep(forTimeInterval: 0.15)
    }

    /// Shows `desktop` on `display`. Returns true when the switch is confirmed.
    static func showDesktop(_ desktop: Int, on display: DisplayInfo, desktopCount: Int?) -> Bool {
        var target = desktop

        if let count = desktopCount, count > 0, desktop > count {
            Log.warn("\(display.name) has \(count) desktop(s); \(desktop) does not exist — using \(count)")
            target = count
        }
        guard target >= 1 else { return false }
        guard target <= 9 else {
            Log.warn("desktop \(target) is not reachable: Mission Control shortcuts stop at 9")
            return false
        }

        aimPointer(at: display)

        guard let layout = load() else {
            Log.debug("space layout unavailable — switching to desktop \(target) without verification")
            postControlDigit(target)
            wait(seconds: 0.6)
            return true
        }

        if layout.currentDesktop(for: display) == target {
            Log.debug("already showing desktop \(target) on \(display.name)")
            return true
        }

        for attempt in 1...2 {
            postControlDigit(target)
            if waitForDesktop(target, on: display) { return true }
            Log.debug("desktop switch to \(target) not confirmed (attempt \(attempt))")
            wait(seconds: 0.35)
        }

        Log.warn("could not switch \(display.name) to desktop \(target) — check that the desktop exists and that Ctrl+\(target) is the enabled Mission Control shortcut")

        if let layout = load() {
            let moved = DisplayRegistry.current().first {
                $0.uuid != display.uuid && layout.currentDesktop(for: $0) == target
            }
            if let other = moved {
                Log.warn("the shortcut changed \(other.name) instead — click once on \(display.name) before running")
            }
        }
        return false
    }

    private static func waitForDesktop(_ desktop: Int, on display: DisplayInfo) -> Bool {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            wait(seconds: 0.2)
            if let layout = load(), layout.currentDesktop(for: display) == desktop { return true }
        }
        return load()?.currentDesktop(for: display) == desktop
    }
}
