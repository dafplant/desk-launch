import AppKit
import Foundation

/// An app the editor can add to a desktop. `bundleID` is what gets written to the
/// config, since it survives the app being renamed or moved.
struct InstalledApp: Identifiable {
    var id: String { path }
    let name: String
    let bundleID: String?
    let path: String
}

enum AppInventory {
    /// The places Launch Services would look. Shallow scan: one level of `.app`.
    static let roots = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    static func scan() -> [InstalledApp] {
        var apps: [InstalledApp] = []
        var seen = Set<String>()

        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = root + "/" + entry
                guard seen.insert(path).inserted else { continue }
                apps.append(make(at: URL(fileURLWithPath: path), fallbackName: entry))
            }
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Reads a dropped `.app` (or the bundle behind a running app).
    static func make(at url: URL, fallbackName: String? = nil) -> InstalledApp {
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? fallbackName
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledApp(
            name: name,
            bundleID: bundle?.bundleIdentifier,
            path: url.path
        )
    }

    /// Nil when the dropped item is not an app bundle, so a stray folder is ignored.
    static func app(atDroppedURL url: URL) -> InstalledApp? {
        let resolved = url.standardizedFileURL
        guard resolved.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return make(at: resolved)
    }

    static func icon(forFile path: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }
}
