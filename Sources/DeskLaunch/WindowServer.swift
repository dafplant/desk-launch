import CoreGraphics
import Foundation

/// Read-only window-server queries for Spaces.
///
/// macOS ships no public API for Spaces. `CGSCopyManagedDisplaySpaces` and
/// `CGSCopySpacesForWindows` live in SkyLight and are what Mission Control itself
/// uses; they are resolved at runtime so the tool still builds and runs if Apple
/// removes them. Callers fall back to `com.apple.spaces`, whose `Current Space`
/// value is written lazily and can be stale — which is exactly why this exists.
enum WindowServer {
    private typealias ConnectionFn = @convention(c) () -> UInt32
    private typealias DisplaySpacesFn = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    private typealias WindowSpacesFn = @convention(c) (UInt32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let framework: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY
    )

    private static let connectionID: UInt32 = {
        guard let framework, let symbol = dlsym(framework, "_CGSDefaultConnection") else { return 0 }
        let function = unsafeBitCast(symbol, to: ConnectionFn.self)
        return function()
    }()

    static var isAvailable: Bool { connectionID != 0 }

    /// One entry per display: identifier, ordered spaces, current space.
    static func displaySpaces() -> [[String: Any]]? {
        guard let framework, connectionID != 0,
              let symbol = dlsym(framework, "CGSCopyManagedDisplaySpaces") else { return nil }
        let function = unsafeBitCast(symbol, to: DisplaySpacesFn.self)
        guard let value = function(connectionID)?.takeRetainedValue() else { return nil }
        return value as? [[String: Any]]
    }

    /// The space a window lives in, including windows on desktops that are not visible.
    static func space(forWindow id: CGWindowID) -> Int? {
        guard let framework, connectionID != 0,
              let symbol = dlsym(framework, "CGSCopySpacesForWindows") else { return nil }
        let function = unsafeBitCast(symbol, to: WindowSpacesFn.self)
        let windows = [NSNumber(value: id)] as CFArray
        guard let value = function(connectionID, 7, windows)?.takeRetainedValue() as? [NSNumber] else {
            return nil
        }
        return value.first?.intValue
    }
}
