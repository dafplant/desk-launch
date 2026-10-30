import AppKit
import SwiftUI

/// Entry point for the config editor. Reached with `desk-launch gui`, or by
/// launching the `.app` bundle that `install.sh` produces.
enum GUI {
    @MainActor
    static func run(configPath: String) {
        let application = NSApplication.shared
        let model = EditorModel(configPath: configPath)
        let delegate = AppDelegate(model: model)
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model: EditorModel
    private var window: NSWindow?
    private var screenObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?

    init(model: EditorModel) {
        self.model = model
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        applyIcon()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Desk Launch"
        window.contentView = NSHostingView(rootView: EditorView(model: model))
        window.minSize = NSSize(width: 940, height: 600)
        window.setFrameAutosaveName("DeskLaunchEditorWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)

        // Plugging or unplugging a display changes the board's shape, and often
        // which profile should be edited.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.model.refreshSystem() }
        }

        // Granting happens in System Settings, so re-check whenever the user
        // comes back instead of making them relaunch the app.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.model.refreshPermission() }
        }

        // Ask once so macOS registers this build for Accessibility; without a
        // prompt the app never appears in the list under its current identity.
        if !model.accessibilityGranted {
            model.requestAccessibility()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in [screenObserver, activeObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// The Dock normally reads the icon out of the app bundle, but `desk-launch
    /// gui` runs the same binary from `.build`, outside any bundle, and would
    /// show the generic executable icon. Setting it explicitly covers both.
    private func applyIcon() {
        let candidates = [
            Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Applications/Desk Launch.app/Contents/Resources/AppIcon.icns"),
        ]
        for case let url? in candidates {
            if let image = NSImage(contentsOf: url) {
                NSApp.applicationIconImage = image
                return
            }
        }
    }

    /// Without a main menu, the standard editing shortcuts and ⌘Q do nothing.
    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Desk Launch", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Desk Launch",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = main
    }
}
