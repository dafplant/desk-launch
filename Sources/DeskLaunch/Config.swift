import Foundation

struct Configuration: Codable {
    var defaults: RunDefaults?
    var profiles: [LaunchProfile]
}

struct RunDefaults: Codable {
    /// Seconds to wait after a step that does not specify its own `wait`.
    var wait: Double?
    /// How long to wait for a launched app to put a window on the target display.
    var windowTimeout: Double?
    /// Pause after a desktop switch, before the app is launched.
    var settle: Double?
    /// When a step's display is missing, use the main display instead of skipping.
    var fallbackToMain: Bool?
    /// Quit an already-running app before launching it again.
    var quitFirst: Bool?

    var resolvedWait: Double { wait ?? 0 }
    var resolvedWindowTimeout: Double { windowTimeout ?? 10 }
    var resolvedSettle: Double { settle ?? 0.8 }
    var resolvedFallbackToMain: Bool { fallbackToMain ?? true }
    var resolvedQuitFirst: Bool { quitFirst ?? false }
}

struct LaunchProfile: Codable {
    var name: String
    var description: String?
    var when: DisplayCondition?
    var steps: [LaunchStep]
}

/// All predicates are ANDed. Any `external*` predicate implies "at least one external display".
struct DisplayCondition: Codable {
    var externalName: String?
    var externalVendor: String?
    var externalUUID: String?
    var externalSerial: String?
    var builtinPresent: Bool?
    var minExternal: Int?
    var maxExternal: Int?
    var anyExternal: Bool?
    /// Matches everything. Use as the last profile.
    var isCatchAll: Bool?
}

struct LaunchStep: Codable {
    /// Bundle identifier ("com.apple.mail"), app name ("Mail") or path ("/Applications/Mail.app").
    var app: String
    /// "builtin", "external", "main", a display name glob, or a display UUID.
    var display: String?
    /// 1-based desktop number on that display.
    var desktop: Int?
    /// Seconds to wait after this step finishes.
    var wait: Double?
    var quitFirst: Bool?
    var note: String?
}

enum ConfigStore {
    static var defaultPath: String {
        NSHomeDirectory() + "/.config/desk-launch/config.json"
    }

    static func load(path: String) throws -> Configuration {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw ConfigError("cannot read config at \(path) (\(error.localizedDescription))")
        }

        let config: Configuration
        do {
            config = try JSONDecoder().decode(Configuration.self, from: data)
        } catch let decodingError as DecodingError {
            throw ConfigError("invalid config at \(path)\n  \(describe(decodingError))")
        } catch {
            throw ConfigError("invalid config at \(path) (\(error.localizedDescription))")
        }

        guard !config.profiles.isEmpty else {
            throw ConfigError("config at \(path) defines no profiles")
        }
        for profile in config.profiles where profile.steps.isEmpty {
            Log.warn("profile \"\(profile.name)\" has no steps")
        }
        return config
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "missing key \"\(key.stringValue)\" at \(pathString(context.codingPath))"
        case .typeMismatch(let type, let context):
            return "expected \(type) at \(pathString(context.codingPath))"
        case .valueNotFound(let type, let context):
            return "missing value of type \(type) at \(pathString(context.codingPath))"
        case .dataCorrupted(let context):
            return "\(context.debugDescription) at \(pathString(context.codingPath))"
        @unknown default:
            return "\(error)"
        }
    }

    private static func pathString(_ path: [CodingKey]) -> String {
        path.map { $0.stringValue }.joined(separator: ".")
    }
}
