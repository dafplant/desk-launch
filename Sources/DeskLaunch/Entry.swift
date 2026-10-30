import Foundation

/// A real `@main` type rather than top-level code, because creating the AppKit
/// application and the SwiftUI editor must happen on the main actor.
@main
enum DeskLaunchMain {
    @MainActor
    static func main() {
        runCLI()
    }
}
