import AppKit
import Foundation

struct ResolvedApp {
    let bundleID: String?
    let name: String
    let url: URL
}

enum AppLauncher {
    static func resolve(_ token: String) -> ResolvedApp? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)

        if trimmed.contains("/") || trimmed.hasSuffix(".app") {
            let path = expandPath(trimmed)
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return make(URL(fileURLWithPath: path))
        }

        if trimmed.contains("."),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) {
            return make(url)
        }

        let directories = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]
        for directory in directories {
            let candidate = directory + "/" + trimmed + ".app"
            if FileManager.default.fileExists(atPath: candidate) {
                return make(URL(fileURLWithPath: candidate))
            }
        }

        return nil
    }

    private static func make(_ url: URL) -> ResolvedApp {
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return ResolvedApp(bundleID: bundle?.bundleIdentifier, name: name, url: url)
    }

    static func running(_ app: ResolvedApp) -> [NSRunningApplication] {
        let all = NSWorkspace.shared.runningApplications
        if let bundleID = app.bundleID {
            return all.filter { $0.bundleIdentifier == bundleID }
        }
        let target = app.url.resolvingSymlinksInPath().standardizedFileURL
        return all.filter { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == target }
    }

    static func isRunning(_ app: ResolvedApp) -> Bool {
        !running(app).isEmpty
    }

    static func pids(for app: ResolvedApp, timeout: Double = 8) -> [pid_t] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let found = running(app).map { $0.processIdentifier }
            if !found.isEmpty { return found }
            wait(seconds: 0.2)
        }
        return []
    }

    /// Launches the app, or activates it if it is already running.
    static func launch(_ app: ResolvedApp) -> Bool {
        if let bundleID = app.bundleID {
            let result = runProcess("/usr/bin/open", ["-b", bundleID])
            if result.status == 0 { return true }
            Log.debug("open -b \(bundleID) failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let result = runProcess("/usr/bin/open", [app.url.path])
        if result.status != 0 {
            Log.warn("could not open \(app.name): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.status == 0
    }

    @discardableResult
    static func quit(_ app: ResolvedApp, timeout: Double = 8) -> Bool {
        let apps = running(app)
        guard !apps.isEmpty else { return true }
        for runningApp in apps { runningApp.terminate() }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if running(app).isEmpty { return true }
            wait(seconds: 0.25)
        }
        for runningApp in running(app) { runningApp.forceTerminate() }
        wait(seconds: 0.5)
        return running(app).isEmpty
    }

    /// Waits until the process owns a visible window on `display`.
    static func waitForWindow(pid: pid_t, on display: DisplayInfo, timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hasWindow(pid: pid, on: display) { return true }
            wait(seconds: 0.25)
        }
        return hasWindow(pid: pid, on: display)
    }

    static func hasWindow(pid: pid_t, on display: DisplayInfo) -> Bool {
        windowRects(pid: pid).contains { $0.intersects(display.bounds) }
    }

    /// Names of the displays that currently hold a window of this process.
    static func displaysWithWindows(pid: pid_t, among displays: [DisplayInfo]) -> [String] {
        let rects = windowRects(pid: pid)
        return displays.filter { display in
            rects.contains { $0.intersects(display.bounds) }
        }.map { $0.name }
    }

    private static func windowRects(pid: pid_t) -> [CGRect] {
        guard let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var rects: [CGRect] = []
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else { continue }
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { continue }
            if let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0.01 { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            guard rect.width >= 80, rect.height >= 80 else { continue }
            rects.append(rect)
        }
        return rects
    }
}
