import AppKit
import Foundation

/// Builds a profile from what is currently on screen: every regular app with a
/// window, the display it sits on, and the desktop — including desktops that are
/// not visible when `allDesktops` is set.
enum CaptureService {
    struct Target {
        let bundleID: String
        let appName: String
        let display: DisplayInfo
        let desktop: Int
        let frame: CGRect
    }

    static func run(
        name: String,
        merge: Bool,
        printOnly: Bool,
        fromProfile: String?,
        excludes: [String],
        allDesktops: Bool,
        configPath: String,
        displays: [DisplayInfo],
        layout: SpaceLayout?
    ) throws {
        let profileName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profileName.isEmpty else {
            throw ConfigError("--name must not be empty")
        }

        var config = try loadOrCreate(configPath)

        let steps: [LaunchStep]
        if let fromProfile {
            guard let source = config.profiles.first(where: {
                $0.name.caseInsensitiveCompare(fromProfile) == .orderedSame
            }) else {
                let names = config.profiles.map { $0.name }.joined(separator: ", ")
                throw ConfigError("no profile named \"\(fromProfile)\" to copy. Available: \(names)")
            }
            Log.heading("Copying steps from \"\(source.name)\"")
            steps = source.steps
        } else {
            let targets = scan(displays: displays, layout: layout, excludes: Set(excludes), allDesktops: allDesktops)
            guard !targets.isEmpty else {
                throw ConfigError("no app windows found on the current desktops")
            }
            report(targets)
            steps = targets.map { step(for: $0, displays: displays) }
        }

        let condition = condition(for: displays)
        let existing = config.profiles.firstIndex(where: {
            $0.name.caseInsensitiveCompare(profileName) == .orderedSame
        })

        if let index = existing {
            guard merge else {
                throw ConfigError(
                    "profile \"\(profileName)\" already exists — pass --merge to add to it, or choose another name"
                )
            }
            let known = config.profiles[index].steps
            let additions = steps.filter { candidate in
                !known.contains { sameTarget($0, candidate) }
            }
            config.profiles[index].steps.append(contentsOf: additions)
            Log.heading("Merged into \"\(profileName)\"")
            Log.raw("  \(additions.count) new step\(additions.count == 1 ? "" : "s"), \(config.profiles[index].steps.count) total")
            if additions.isEmpty {
                Log.raw("  nothing new on this desktop")
            }
        } else {
            let profile = LaunchProfile(
                name: profileName,
                description: "Captured \(timestamp()) from \(displaySummary(displays))",
                when: condition,
                steps: steps
            )
            // Profiles are first-match-wins, so a captured profile must land before
            // any catch-all or it could never be selected.
            let insertAt = config.profiles.firstIndex { $0.when?.isCatchAll == true } ?? config.profiles.count
            config.profiles.insert(profile, at: insertAt)
            Log.heading("Created profile \"\(profileName)\"")
        }

        if printOnly {
            let encoder = makeEncoder()
            let profile = config.profiles.first { $0.name.caseInsensitiveCompare(profileName) == .orderedSame }
            if let profile, let data = try? encoder.encode(profile),
               let text = String(data: data, encoding: .utf8) {
                Log.raw("")
                Log.raw(text)
            }
            Log.raw("")
            Log.raw("  (not written: --print-only)")
            return
        }

        let data = try makeEncoder().encode(config)
        try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
        Log.raw("")
        Log.ok("Wrote \(configPath)")
        Log.raw("  Check it with: desk-launch --dry-run --profile \(profileName)")
        Log.raw("  Include every desktop next time with --all-desktops; --merge adds newly opened apps")
    }

    // MARK: - Observation

    private static func scan(
        displays: [DisplayInfo],
        layout: SpaceLayout?,
        excludes: Set<String>,
        allDesktops: Bool
    ) -> [Target] {
        let options: CGWindowListOption = allDesktops
            ? [.optionAll, .excludeDesktopElements]
            : [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var byPID: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            byPID[app.processIdentifier] = app
        }

        var targets: [Target] = []
        var seen = Set<String>()
        let spaceIndex = spaceIndexMap(displays: displays, layout: layout)

        for window in windows {
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { continue }
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            guard let app = byPID[pid], app.activationPolicy == .regular else { continue }
            guard let bundleID = app.bundleIdentifier, !excludes.contains(bundleID) else { continue }
            if let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0.01 { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            guard frame.width >= 100, frame.height >= 80 else { continue }
            guard var display = bestDisplay(for: frame, in: displays) else { continue }

            // The window's own space is authoritative: it is correct even for
            // desktops that are not currently visible on that display.
            var desktop: Int?
            if let windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
               let space = WindowServer.space(forWindow: windowID),
               let located = spaceIndex[space] {
                display = located.display
                desktop = located.desktop
            } else if allDesktops {
                // Without a space the window is a stray panel, not a desktop occupant.
                continue
            }
            let resolvedDesktop = desktop ?? layout?.currentDesktop(for: display) ?? 1

            let key = "\(bundleID)|\(display.uuid)|\(resolvedDesktop)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            targets.append(
                Target(
                    bundleID: bundleID,
                    appName: app.localizedName ?? bundleID,
                    display: display,
                    desktop: resolvedDesktop,
                    frame: frame
                )
            )
        }

        let order = displayOrder(displays)
        return targets.sorted { lhs, rhs in
            let left = (order[lhs.display.uuid] ?? 99, lhs.desktop, lhs.frame.minX)
            let right = (order[rhs.display.uuid] ?? 99, rhs.desktop, rhs.frame.minX)
            if left.0 != right.0 { return left.0 < right.0 }
            if left.1 != right.1 { return left.1 < right.1 }
            return left.2 < right.2
        }
    }

    /// Maps every ManagedSpaceID on every display to its display and 1-based desktop.
    private static func spaceIndexMap(
        displays: [DisplayInfo],
        layout: SpaceLayout?
    ) -> [Int: (display: DisplayInfo, desktop: Int)] {
        guard let layout else { return [:] }
        var map: [Int: (display: DisplayInfo, desktop: Int)] = [:]
        for display in displays {
            guard let ids = layout.spaceIDs(for: display) else { continue }
            for (offset, id) in ids.enumerated() {
                map[id] = (display, offset + 1)
            }
        }
        return map
    }

    private static func displayOrder(_ displays: [DisplayInfo]) -> [String: Int] {        var order: [String: Int] = [:]
        let sorted = displays.sorted { lhs, rhs in
            if lhs.isBuiltin != rhs.isBuiltin { return lhs.isBuiltin }
            return lhs.bounds.minX < rhs.bounds.minX
        }
        for (index, display) in sorted.enumerated() { order[display.uuid] = index }
        return order
    }

    private static func bestDisplay(for frame: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        var best: (display: DisplayInfo, area: CGFloat)?
        for display in displays {
            let intersection = display.bounds.intersection(frame)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if area > (best?.area ?? 0) { best = (display, area) }
        }
        if let best { return best.display }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.first { $0.bounds.contains(center) }
    }

    // MARK: - Profile construction

    private static func step(for target: Target, displays: [DisplayInfo]) -> LaunchStep {
        LaunchStep(
            app: target.bundleID,
            display: selector(for: target.display, displays: displays),
            desktop: target.desktop,
            wait: nil,
            quitFirst: nil,
            note: nil
        )
    }

    /// How a step should refer to `display`: "builtin", "external" when there is
    /// only one external, otherwise the display's name. Shared with the editor.
    static func selector(for display: DisplayInfo, displays: [DisplayInfo]) -> String {
        if display.isBuiltin { return "builtin" }
        let externals = displays.filter { !$0.isBuiltin }
        return externals.count == 1 ? "external" : display.name
    }

    /// The `when` block for the displays attached right now. Shared with the editor.
    static func condition(for displays: [DisplayInfo]) -> DisplayCondition {
        let externals = displays.filter { !$0.isBuiltin }
        let builtinPresent = displays.contains { $0.isBuiltin }
        return DisplayCondition(
            externalName: externals.first?.name,
            externalVendor: nil,
            externalModel: nil,
            externalUUID: nil,
            externalSerial: nil,
            builtinPresent: builtinPresent,
            minExternal: nil,
            maxExternal: externals.count > 1 ? externals.count : nil,
            anyExternal: externals.isEmpty ? false : nil,
            isCatchAll: nil
        )
    }

    private static func sameTarget(_ lhs: LaunchStep, _ rhs: LaunchStep) -> Bool {
        lhs.app == rhs.app
            && (lhs.display ?? "main") == (rhs.display ?? "main")
            && (lhs.desktop ?? 1) == (rhs.desktop ?? 1)
    }

    // MARK: - Output

    private static func report(_ targets: [Target]) {
        Log.heading("On screen now")
        for (index, target) in targets.enumerated() {
            let desktop = "desktop \(target.desktop)"
            Log.raw("  \(index + 1). \(target.appName) → \(target.display.name), \(desktop)")
        }
    }

    private static func displaySummary(_ displays: [DisplayInfo]) -> String {
        let externals = displays.filter { !$0.isBuiltin }
        if externals.isEmpty { return "built-in display only" }
        return displays.map { $0.isBuiltin ? "built-in" : $0.name }.joined(separator: " + ")
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    private static func loadOrCreate(_ path: String) throws -> Configuration {
        guard FileManager.default.fileExists(atPath: path) else {
            return Configuration(defaults: nil, profiles: [])
        }
        return try ConfigStore.load(path: path)
    }

    /// Helper for the CLI: the system UI processes that never belong in a profile.
    static let defaultExcludes: Set<String> = [
        "com.apple.dock",
        "com.apple.finder",
        "com.apple.WindowManager",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
        "com.apple.loginwindow",
        "com.apple.Spotlight",
        "com.apple.screencaptureui",
        "com.apple.UserNotificationCenter",
    ]
}
