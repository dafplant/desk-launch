import AppKit
import Foundation

struct Options {
    var configPath: String?
    var profile: String?
    var capture = false
    var captureName: String?
    var merge = false
    var printOnly = false
    var fromProfile: String?
    var excludes: [String] = []
    var allDesktops = false
    var dryRun = false
    var verbose = false
    var listDisplays = false
    var listProfiles = false
    var doctor = false
    var noWait = false
    var testDesktops = false
    var help = false
}

let usageText = """
desk-launch — open apps on specific desktops, per display

USAGE
  desk-launch [options]
  desk-launch capture --name <profile> [options]

OPTIONS
  --profile <name>   Run a specific profile instead of the first matching one
  --dry-run          Print the plan; touch nothing
  --list-displays    Show connected displays, desktop counts and current desktop
  --list-profiles    Show profiles and whether they match this setup
  --doctor           Diagnostics: displays, desktops, permissions, shortcuts
  --test-desktops    Cycle each display through its desktops and report whether
                     switching was confirmed, then restore the original desktops
  --config <path>    Config file (default ~/.config/desk-launch/config.json)
  --no-wait          Ignore configured waits (for testing)
  --verbose          Extra detail; with --list-displays, shows UUID, vendor,
                     model and serial
  -h, --help         This text

CAPTURE
  desk-launch capture --name <profile>
      Save what is on screen now as a profile: each app, its display, and that
      display's current desktop.
  --merge            Add the current screen to an existing profile instead
  --from-profile <n> Copy the steps of profile <n> instead of scanning the screen
  --print-only       Show the profile JSON without writing the config
  --all-desktops     Include windows on desktops that are not currently visible
  --exclude <id>     Skip an app bundle id (repeatable)

CONFIG
  ~/.config/desk-launch/config.json
"""

enum Runner {
    static func run(_ options: Options) throws {
        let configPath = expandPath(options.configPath ?? ConfigStore.defaultPath)
        let displays = DisplayRegistry.current()
        let layout = SpacesService.load()

        if options.listDisplays {
            printDisplays(displays, layout: layout)
            return
        }

        if options.capture {
            guard let name = options.captureName else {
                throw ConfigError("capture needs --name <profile>")
            }
            try CaptureService.run(
                name: name,
                merge: options.merge,
                printOnly: options.printOnly,
                fromProfile: options.fromProfile,
                excludes: Array(CaptureService.defaultExcludes) + options.excludes,
                allDesktops: options.allDesktops,
                configPath: configPath,
                displays: displays,
                layout: layout
            )
            return
        }

        let config = FileManager.default.fileExists(atPath: configPath)
            ? try ConfigStore.load(path: configPath)
            : nil

        if options.listProfiles {
            guard let config else { throw ConfigError("no config at \(configPath)") }
            printProfiles(config, displays: displays)
            return
        }

        if options.doctor {
            printDoctor(config: config, configPath: configPath, displays: displays, layout: layout)
            return
        }

        if options.testDesktops {
            try testDesktops(displays: displays, layout: layout)
            return
        }

        guard let config else {
            throw ConfigError("no config at \(configPath)\n  Run install.sh to create one, or pass --config <path>")
        }

        let defaults = config.defaults ?? RunDefaults()
        let profile = try selectProfile(config, displays: displays, requested: options.profile)

        var header = profile.name
        if let description = profile.description { header += " — \(description)" }
        Log.heading("Profile: \(header)")
        printDisplays(displays, layout: layout, indent: true, heading: false)
        Log.raw("")

        if options.dryRun {
            printPlan(profile, defaults: defaults, displays: displays, layout: layout, options: options)
            return
        }

        guard SpacesService.accessibilityEnabled(prompt: true) else {
            throw ConfigError(
                "Accessibility permission is required to switch desktops.\n" +
                "  System Settings → Privacy & Security → Accessibility → enable your terminal app\n" +
                "  (Ghostty, iTerm, Terminal), then run this command again."
            )
        }

        let originalPointer = CGEvent(source: nil)?.location
        defer {
            if let originalPointer { CGWarpMouseCursorPosition(originalPointer) }
        }

        let counts = desktopCounts(displays, layout: layout)

        for (offset, step) in profile.steps.enumerated() {
            execute(
                step: step,
                number: offset + 1,
                total: profile.steps.count,
                defaults: defaults,
                displays: displays,
                counts: counts,
                options: options
            )
        }

        Log.heading("Done")
    }

    // MARK: - Execution

    private static func execute(
        step: LaunchStep,
        number: Int,
        total: Int,
        defaults: RunDefaults,
        displays: [DisplayInfo],
        counts: [String: Int],
        options: Options
    ) {
        Log.heading("Step \(number)/\(total) · \(step.app)")

        guard let app = AppLauncher.resolve(step.app) else {
            Log.warn("cannot find app \"\(step.app)\" — skipping")
            return
        }

        let spec = step.display ?? "main"
        var display = DisplayRegistry.resolve(spec, in: displays)
        if display == nil {
            if defaults.resolvedFallbackToMain, let main = DisplayRegistry.main(displays) {
                Log.warn("display \"\(spec)\" is not connected — using \(main.name) (main display)")
                display = main
            } else {
                Log.skip("display \"\(spec)\" is not connected — skipping \(app.name)")
                return
            }
        }
        guard let target = display else { return }

        let requestedDesktop = step.desktop ?? 1
        var desktop = requestedDesktop
        if let count = counts[target.uuid], count > 0, requestedDesktop > count {
            Log.warn("\(target.name) has \(count) desktop(s); \(requestedDesktop) does not exist — using \(count)")
            desktop = count
        }

        let quitFirst = step.quitFirst ?? defaults.resolvedQuitFirst
        var wasRunning = AppLauncher.isRunning(app)
        if quitFirst, wasRunning {
            Log.action("quitting \(app.name)")
            if !AppLauncher.quit(app) { Log.warn("\(app.name) did not quit") }
            wasRunning = false
        } else if wasRunning {
            Log.debug("\(app.name) is already running — activating it")
        }

        _ = SpacesService.showDesktop(desktop, on: target, desktopCount: counts[target.uuid])
        wait(seconds: defaults.resolvedSettle)

        Log.action("opening \(app.name) on \(target.name), desktop \(desktop)")
        guard AppLauncher.launch(app) else { return }

        if wasRunning {
            // Activating an existing app can pull its display to the app's own desktop.
            // Re-assert the requested one so the run always ends where the config says.
            wait(seconds: 0.3)
            _ = SpacesService.showDesktop(desktop, on: target, desktopCount: counts[target.uuid])
        }

        if let pid = AppLauncher.pids(for: app).first {
            if AppLauncher.waitForWindow(pid: pid, on: target, timeout: defaults.resolvedWindowTimeout) {
                Log.ok("\(app.name) window is on \(target.name)")
            } else {
                let elsewhere = AppLauncher.displaysWithWindows(pid: pid, among: displays)
                    .filter { $0 != target.name }
                if let other = elsewhere.first {
                    Log.warn("\(app.name) opened on \(other) instead of \(target.name) — an already-running window can't be moved, set \"quitFirst\": true to fix it")
                } else {
                    Log.warn("no \(app.name) window appeared on \(target.name) within \(Int(defaults.resolvedWindowTimeout))s — the app may still be starting")
                }
            }
        } else {
            Log.warn("\(app.name) did not start")
        }

        let delay = options.noWait ? 0 : (step.wait ?? defaults.resolvedWait)
        if delay > 0 {
            Log.debug("waiting \(formatSeconds(delay))")
            wait(seconds: delay)
        }
    }

    // MARK: - Profile selection

    private static func selectProfile(
        _ config: Configuration,
        displays: [DisplayInfo],
        requested: String?
    ) throws -> LaunchProfile {
        if let requested {
            guard let match = config.profiles.first(where: {
                $0.name.caseInsensitiveCompare(requested) == .orderedSame
            }) else {
                let names = config.profiles.map { $0.name }.joined(separator: ", ")
                throw ConfigError("no profile named \"\(requested)\". Available: \(names)")
            }
            return match
        }

        if let match = config.profiles.first(where: { matches($0.when, displays: displays) }) {
            return match
        }

        let summary = displays.map { $0.label }.joined(separator: "; ")
        throw ConfigError(
            "no profile matches the connected displays (\(summary))\n" +
            "  Add a catch-all profile with \"when\": { \"isCatchAll\": true }"
        )
    }

    static func matches(_ condition: DisplayCondition?, displays: [DisplayInfo]) -> Bool {
        guard let condition else { return true }
        if condition.isCatchAll == true { return true }

        let externals = displays.filter { !$0.isBuiltin }

        if let pattern = condition.externalName,
           !externals.contains(where: { globMatch(pattern, $0.name) }) { return false }

        if let pattern = condition.externalVendor,
           !externals.contains(where: {
               globMatch(pattern, $0.vendorHex) || globMatch(pattern, vendorName($0.vendor))
           }) { return false }

        if let pattern = condition.externalModel,
           !externals.contains(where: {
               globMatch(pattern, String($0.model)) || globMatch(pattern, $0.modelHex)
           }) { return false }

        if let pattern = condition.externalUUID,
           !externals.contains(where: { globMatch(pattern, $0.uuid) }) { return false }

        if let pattern = condition.externalSerial,
           !externals.contains(where: { globMatch(pattern, String($0.serial)) }) { return false }

        if let present = condition.builtinPresent,
           present != displays.contains(where: { $0.isBuiltin }) { return false }

        if let minimum = condition.minExternal, externals.count < minimum { return false }
        if let maximum = condition.maxExternal, externals.count > maximum { return false }
        if let any = condition.anyExternal, any != !externals.isEmpty { return false }

        return true
    }

    // MARK: - Reporting

    private static func desktopCounts(_ displays: [DisplayInfo], layout: SpaceLayout?) -> [String: Int] {
        guard let layout else { return [:] }
        var counts: [String: Int] = [:]
        for display in displays {
            if let count = layout.desktopCount(for: display) { counts[display.uuid] = count }
        }
        return counts
    }

    private static func printDisplays(
        _ displays: [DisplayInfo],
        layout: SpaceLayout?,
        indent: Bool = false,
        heading: Bool = true
    ) {
        if heading { Log.heading("Displays") }
        for display in displays {
            var line = display.label
            if let layout {
                if let count = layout.desktopCount(for: display) {
                    line += "  — \(count) desktop\(count == 1 ? "" : "s")"
                    if let current = layout.currentDesktop(for: display) {
                        line += ", showing \(current)"
                    }
                }
            } else {
                line += "  — desktops unavailable"
            }
            let prefix = indent ? "    " : "  "
            Log.raw(prefix + line)
            if Log.verbose {
                Log.raw(
                    prefix + "  uuid \(display.uuid) · vendor \(display.vendorHex)"
                        + " (\(vendorName(display.vendor))) · model \(display.modelHex)"
                        + " · serial \(display.serial)"
                )
            }
        }
    }

    private static func printProfiles(_ config: Configuration, displays: [DisplayInfo]) {
        Log.heading("Profiles")
        for profile in config.profiles {
            let matched = matches(profile.when, displays: displays)
            let marker = matched ? "matches this setup" : "does not match"
            Log.raw("  \(profile.name)  — \(marker)")
            if let description = profile.description {
                Log.raw("    \(description)")
            }
            for (index, step) in profile.steps.enumerated() {
                let app = AppLauncher.resolve(step.app)?.name ?? step.app
                let display = step.display ?? "main"
                let desktop = step.desktop ?? 1
                var line = "    \(index + 1). \(app) → \(display), desktop \(desktop)"
                if let wait = step.wait, wait > 0 { line += " (wait \(formatSeconds(wait)))" }
                Log.raw(line)
            }
        }
    }

    private static func printPlan(
        _ profile: LaunchProfile,
        defaults: RunDefaults,
        displays: [DisplayInfo],
        layout: SpaceLayout?,
        options: Options
    ) {
        let counts = desktopCounts(displays, layout: layout)
        Log.heading("Plan (dry run — nothing will change)")

        var estimated: Double = 0
        for (index, step) in profile.steps.enumerated() {
            let app = AppLauncher.resolve(step.app)?.name ?? step.app
            let spec = step.display ?? "main"
            var display = DisplayRegistry.resolve(spec, in: displays)
            var suffix = ""

            if display == nil {
                if defaults.resolvedFallbackToMain, let main = DisplayRegistry.main(displays) {
                    display = main
                    suffix = "  (fallback: \"\(spec)\" not connected)"
                } else {
                    Log.raw("  \(index + 1). \(app) → skipped (no display \"\(spec)\")")
                    continue
                }
            }

            guard let target = display else { continue }
            var desktop = step.desktop ?? 1
            if let count = counts[target.uuid], count > 0, desktop > count {
                desktop = count
                suffix += "  (clamped: only \(count) desktop\(count == 1 ? "" : "s"))"
            }

            Log.raw("  \(index + 1). \(app) → \(target.name), desktop \(desktop)\(suffix)")
            estimated += defaults.resolvedSettle
            estimated += options.noWait ? 0 : (step.wait ?? defaults.resolvedWait)
        }

        Log.raw("")
        Log.raw("  Minimum runtime: ≈\(formatSeconds(estimated)) plus app launch time")
    }

    /// Cycles every display through its desktops, reporting whether each switch was
    /// confirmed, then puts each display back where it started. Launches nothing.
    private static func testDesktops(displays: [DisplayInfo], layout: SpaceLayout?) throws {
        guard SpacesService.accessibilityEnabled(prompt: true) else {
            throw ConfigError(
                "Accessibility permission is required to switch desktops.\n" +
                "  System Settings → Privacy & Security → Accessibility → enable your terminal app\n" +
                "  (Ghostty, iTerm, Terminal), then run this command again."
            )
        }

        let originalPointer = CGEvent(source: nil)?.location
        defer {
            if let originalPointer { CGWarpMouseCursorPosition(originalPointer) }
        }

        Log.heading("Desktop switching test")
        var failures = 0

        for display in displays {
            guard let count = layout?.desktopCount(for: display), count > 0 else {
                Log.skip("\(display.name): desktop count unknown")
                continue
            }
            let start = layout?.currentDesktop(for: display)
            let limit = min(count, 9)

            for desktop in 1...limit {
                if SpacesService.showDesktop(desktop, on: display, desktopCount: count) {
                    Log.ok("\(display.name) → desktop \(desktop)")
                } else {
                    failures += 1
                }
            }

            if let start, start != limit {
                _ = SpacesService.showDesktop(start, on: display, desktopCount: count)
            }
        }

        Log.raw("")
        if failures == 0 {
            Log.ok("every desktop switch was confirmed")
        } else {
            throw ConfigError("\(failures) desktop switch(es) failed — see the warnings above")
        }
    }

    private static func printDoctor(
        config: Configuration?,
        configPath: String,
        displays: [DisplayInfo],
        layout: SpaceLayout?
    ) {
        printDisplays(displays, layout: layout)

        Log.heading("Config")
        Log.raw("  \(configPath)\(config == nil ? "  (missing)" : "")")
        if let config {
            let matching = config.profiles.first(where: { matches($0.when, displays: displays) })
            Log.raw("  active profile: \(matching?.name ?? "none — add a catch-all profile")")
            let summary = config.profiles.map { profile -> String in
                matches(profile.when, displays: displays) ? "\(profile.name) ✓" : profile.name
            }
            Log.raw("  profiles: \(summary.joined(separator: ", "))")
        }

        Log.heading("Permissions")
        let trusted = SpacesService.accessibilityEnabled(prompt: false)
        if trusted {
            Log.raw("  Accessibility: granted")
        } else {
            Log.raw("  Accessibility: NOT granted — desktop switching will not work")
            Log.raw("    System Settings → Privacy & Security → Accessibility → enable your terminal app")
            Log.raw("    Then quit and reopen the terminal.")
        }

        let shortcuts = SpacesService.shortcutStatus()
        if shortcuts.isEmpty {
            Log.raw("  Mission Control shortcuts: could not read com.apple.symbolichotkeys")
        } else {
            let enabled = shortcuts.filter { $0.value }.keys.sorted()
            let missing = shortcuts.filter { !$0.value }.keys.sorted()
            Log.raw("  Ctrl+1…9 switching enabled: \(enabled.map(String.init).joined(separator: ", "))")
            if !missing.isEmpty {
                Log.raw("  disabled: \(missing.map(String.init).joined(separator: ", "))")
            }
        }
    }
}

func formatSeconds(_ value: Double) -> String {
    if value == value.rounded() { return "\(Int(value))s" }
    return String(format: "%.1fs", value)
}

// MARK: - Entry point

var options = Options()
var index = 1
while index < CommandLine.arguments.count {
    let argument = CommandLine.arguments[index]
    switch argument {
    case "--config":
        index += 1
        guard index < CommandLine.arguments.count else {
            Log.fail("--config needs a path")
            exit(2)
        }
        options.configPath = CommandLine.arguments[index]
    case "--profile":
        index += 1
        guard index < CommandLine.arguments.count else {
            Log.fail("--profile needs a name")
            exit(2)
        }
        options.profile = CommandLine.arguments[index]
    case "--dry-run", "-n":
        options.dryRun = true
    case "capture":
        options.capture = true
    case "--name":
        index += 1
        guard index < CommandLine.arguments.count else {
            Log.fail("--name needs a value")
            exit(2)
        }
        options.captureName = CommandLine.arguments[index]
    case "--merge":
        options.merge = true
    case "--print-only":
        options.printOnly = true
    case "--all-desktops":
        options.allDesktops = true
    case "--from-profile":
        index += 1
        guard index < CommandLine.arguments.count else {
            Log.fail("--from-profile needs a name")
            exit(2)
        }
        options.fromProfile = CommandLine.arguments[index]
    case "--exclude":
        index += 1
        guard index < CommandLine.arguments.count else {
            Log.fail("--exclude needs a bundle id")
            exit(2)
        }
        options.excludes.append(CommandLine.arguments[index])
    case "--list-displays":
        options.listDisplays = true
    case "--list-profiles":
        options.listProfiles = true
    case "--doctor":
        options.doctor = true
    case "--test-desktops":
        options.testDesktops = true
    case "--no-wait":
        options.noWait = true
    case "--verbose", "-v":
        options.verbose = true
    case "--help", "-h":
        options.help = true
    default:
        Log.fail("unknown option \(argument)")
        print(usageText)
        exit(2)
    }
    index += 1
}

if options.help {
    print(usageText)
    exit(0)
}

Log.verbose = options.verbose
Log.color = isatty(STDOUT_FILENO) == 1

do {
    try Runner.run(options)
} catch let error as ConfigError {
    Log.fail(error.description)
    exit(1)
} catch {
    Log.fail("\(error)")
    exit(1)
}
