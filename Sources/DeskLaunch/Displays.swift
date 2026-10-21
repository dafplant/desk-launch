import AppKit
import Foundation

struct DisplayInfo {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    let isBuiltin: Bool
    let isMain: Bool
    /// Global display bounds, top-left origin (CoreGraphics space).
    let bounds: CGRect
    let vendor: Int
    let model: Int
    let serial: Int

    var vendorHex: String { String(format: "0x%04x", vendor) }
    var kind: String { isBuiltin ? "built-in" : "external" }

    var label: String {
        let tags = [kind, isMain ? "main" : nil].compactMap { $0 }.joined(separator: ", ")
        return "\(name) (\(tags)) \(Int(bounds.width))×\(Int(bounds.height))"
    }

    /// A point in the middle of the display, used to aim pointer-driven shortcuts.
    var aimPoint: CGPoint {
        CGPoint(x: bounds.midX, y: bounds.minY + bounds.height * 0.35)
    }
}

enum DisplayRegistry {
    static func current() -> [DisplayInfo] {
        let mainID = CGMainDisplayID()
        var displays: [DisplayInfo] = []

        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let id = CGDirectDisplayID(number.uint32Value)
            displays.append(
                DisplayInfo(
                    id: id,
                    uuid: uuidString(for: id),
                    name: screen.localizedName,
                    isBuiltin: CGDisplayIsBuiltin(id) != 0,
                    isMain: id == mainID,
                    bounds: CGDisplayBounds(id),
                    vendor: Int(CGDisplayVendorNumber(id)),
                    model: Int(CGDisplayModelNumber(id)),
                    serial: Int(CGDisplaySerialNumber(id))
                )
            )
        }
        return displays
    }

    static func uuidString(for id: CGDirectDisplayID) -> String {
        guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(id) else { return "" }
        let uuid = unmanaged.takeRetainedValue()
        let string = CFUUIDCreateString(nil, uuid) as String
        return string.uppercased()
    }

    static func main(_ displays: [DisplayInfo]) -> DisplayInfo? {
        displays.first(where: { $0.isMain }) ?? displays.first
    }

    /// Resolves a step's `display` string.
    static func resolve(_ spec: String?, in displays: [DisplayInfo]) -> DisplayInfo? {
        let trimmed = (spec ?? "main").trimmingCharacters(in: .whitespaces)
        switch trimmed.lowercased() {
        case "builtin", "built-in", "internal", "laptop":
            return displays.first(where: { $0.isBuiltin })
        case "main", "primary":
            return main(displays)
        case "external", "second":
            return displays.first(where: { !$0.isBuiltin && !$0.isMain })
                ?? displays.first(where: { !$0.isBuiltin })
        default:
            return displays.first(where: {
                $0.uuid.caseInsensitiveCompare(trimmed) == .orderedSame || globMatch(trimmed, $0.name)
            })
        }
    }
}

/// Best-effort vendor names, for readable matching (`externalVendor: "LG"`).
func vendorName(_ vendor: Int) -> String {
    switch vendor {
    case 0x0610: return "Apple"
    case 0x1E6D: return "LG"
    case 0x09D1: return "BenQ"
    case 0x10AC: return "Dell"
    case 0x04B3: return "IBM"
    case 0x0469: return "Acer"
    case 0x0BDA: return "Realtek"
    default: return "unknown"
    }
}
