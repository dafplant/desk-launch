import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Everything the editor window shows and does. The config file stays the source
/// of truth: this only reads it, edits it in memory, and writes it back in the
/// same normalised form `desk-launch capture` produces.
@MainActor
final class EditorModel: ObservableObject {
    /// A place an app can live: one desktop on one display. `displayUUID` is
    /// empty for steps whose display is not connected right now.
    struct ColumnKey: Hashable, Identifiable {
        var displayUUID: String
        var desktop: Int
        var id: String { "\(displayUUID)#\(desktop)" }
    }

    struct StepItem: Identifiable {
        let id: UUID
        var step: LaunchStep

        init(_ step: LaunchStep) {
            self.id = UUID()
            self.step = step
        }
    }

    /// Profiles have no identity in the JSON, but SwiftUI needs a stable one
    /// while the user renames, reorders and deletes them.
    struct ProfileItem: Identifiable {
        let id: UUID
        var name: String
        var description: String
        var when: DisplayCondition?
        var steps: [StepItem]

        init(_ profile: LaunchProfile) {
            self.id = UUID()
            self.name = profile.name
            self.description = profile.description ?? ""
            self.when = profile.when
            self.steps = profile.steps.map(StepItem.init)
        }

        init(name: String, description: String, when: DisplayCondition?, steps: [LaunchStep] = []) {
            self.id = UUID()
            self.name = name
            self.description = description
            self.when = when
            self.steps = steps.map(StepItem.init)
        }

        func asProfile() -> LaunchProfile {
            let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
            return LaunchProfile(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                description: trimmedDescription.isEmpty ? nil : trimmedDescription,
                when: when,
                steps: steps.map(\.step)
            )
        }
    }

    // MARK: - State

    @Published var configPath: String
    @Published var defaults: RunDefaults
    @Published var profiles: [ProfileItem] = []
    @Published var selection: UUID?

    @Published var displays: [DisplayInfo] = []
    @Published var layout: SpaceLayout?
    @Published var columnCounts: [String: Int] = [:]

    @Published var accessibilityGranted = false
    @Published var disabledShortcuts: [Int] = []

    @Published var dirty = false
    @Published var status = ""
    @Published var errorMessage: String?

    @Published var log = ""
    @Published var logVisible = false
    @Published var isRunning = false

    @Published var browserTarget: ColumnKey?
    @Published var installedApps: [InstalledApp] = []
    @Published var scanningApps = false

    private var runningProcess: Process?
    private var resolvedApps: [String: ResolvedApp] = [:]
    private var icons: [String: NSImage] = [:]

    // MARK: - Lifecycle

    init(configPath: String) {
        self.configPath = configPath
        self.defaults = RunDefaults()
        refreshSystem()
        loadFromDisk()
    }

    func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: configPath) else {
            profiles = []
            selection = nil
            dirty = false
            status = "No config yet — add a profile to create one"
            return
        }
        do {
            let config = try ConfigStore.load(path: configPath)
            defaults = config.defaults ?? RunDefaults()
            profiles = config.profiles.map(ProfileItem.init)
            if selection == nil || !profiles.contains(where: { $0.id == selection }) {
                selection = profiles.first?.id
            }
            dirty = false
            status = "Loaded \(configPath)"
            recountColumns()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func refreshSystem() {
        displays = DisplayRegistry.current()
        layout = SpacesService.load()
        accessibilityGranted = SpacesService.accessibilityEnabled(prompt: false)
        let shortcuts = SpacesService.shortcutStatus()
        disabledShortcuts = (1...9).filter { shortcuts[$0] == false }
        recountColumns()
    }

    // MARK: - Selection

    var selectedIndex: Int? {
        guard let selection else { return nil }
        return profiles.firstIndex { $0.id == selection }
    }

    var selectedProfile: ProfileItem? {
        selectedIndex.map { profiles[$0] }
    }

    func profile(at index: Int) -> ProfileItem? {
        profiles.indices.contains(index) ? profiles[index] : nil
    }

    func profile(id: UUID) -> ProfileItem? {
        profiles.first { $0.id == id }
    }

    /// Bindings look profiles up by identity, so deleting the selected row can't
    /// leave a text field pointed at an index that no longer exists.
    func nameBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { self.profiles.first(where: { $0.id == id })?.name ?? "" },
            set: { value in
                guard let index = self.profiles.firstIndex(where: { $0.id == id }),
                      self.profiles[index].name != value else { return }
                self.profiles[index].name = value
                self.dirty = true
            }
        )
    }

    func descriptionBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { self.profiles.first(where: { $0.id == id })?.description ?? "" },
            set: { value in
                guard let index = self.profiles.firstIndex(where: { $0.id == id }),
                      self.profiles[index].description != value else { return }
                self.profiles[index].description = value
                self.dirty = true
            }
        )
    }

    // MARK: - Profile edits

    func newProfile() {
        let condition = CaptureService.condition(for: displays)
        let item = ProfileItem(
            name: uniqueName(base: "setup"),
            description: displaySummary(),
            when: condition,
            steps: []
        )
        // Profiles are first-match-wins, so a new setup-specific profile belongs
        // before any catch-all or it could never be selected.
        let insertAt = profiles.firstIndex { $0.when?.isCatchAll == true } ?? profiles.count
        profiles.insert(item, at: insertAt)
        selection = item.id
        dirty = true
        status = "Created \"\(item.name)\" for this display setup"
    }

    func duplicateSelected() {
        guard let index = selectedIndex else { return }
        let source = profiles[index]
        let copy = ProfileItem(
            name: uniqueName(base: source.name + "-copy"),
            description: source.description,
            when: source.when,
            steps: source.steps.map(\.step)
        )
        profiles.insert(copy, at: index + 1)
        selection = copy.id
        dirty = true
    }

    func deleteSelected() {
        guard profiles.count > 1, let index = selectedIndex else { return }
        profiles.remove(at: index)
        selection = profiles[min(index, profiles.count - 1)].id
        dirty = true
    }

    /// Matching is first-match-wins, so the order of the sidebar is behaviour.
    func canMoveSelected(up: Bool) -> Bool {
        guard let index = selectedIndex else { return false }
        return profiles.indices.contains(up ? index - 1 : index + 1)
    }

    func moveSelected(up: Bool) {
        guard let index = selectedIndex else { return }
        let target = up ? index - 1 : index + 1
        guard profiles.indices.contains(target) else { return }
        profiles.swapAt(index, target)
        dirty = true
    }

    /// Rebuilds `when` from the displays attached right now, the same way
    /// `desk-launch capture` does.
    func rebindConditionToCurrentSetup() {
        guard let index = selectedIndex else { return }
        profiles[index].when = CaptureService.condition(for: displays)
        dirty = true
        status = "Profile now matches \(displaySummary())"
    }

    func makeCatchAll() {
        guard let index = selectedIndex else { return }
        profiles[index].when = DisplayCondition(
            externalName: nil,
            externalVendor: nil,
            externalModel: nil,
            externalUUID: nil,
            externalSerial: nil,
            builtinPresent: nil,
            minExternal: nil,
            maxExternal: nil,
            anyExternal: nil,
            isCatchAll: true
        )
        dirty = true
        status = "Profile now matches any display setup — keep it last"
    }

    private func uniqueName(base: String) -> String {
        let existing = Set(profiles.map { $0.name.lowercased() })
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard existing.contains(trimmed.lowercased()) else { return trimmed }
        var counter = 2
        while existing.contains("\(trimmed)-\(counter)".lowercased()) { counter += 1 }
        return "\(trimmed)-\(counter)"
    }

    // MARK: - Columns

    func columnCount(display: DisplayInfo) -> Int {
        max(1, columnCounts[display.uuid] ?? 1)
    }

    func detectedCount(display: DisplayInfo) -> Int? {
        guard let count = layout?.desktopCount(for: display) else { return nil }
        return count
    }

    func detectedLabel(display: DisplayInfo) -> String {
        guard let count = layout?.desktopCount(for: display) else {
            return "desktop count unavailable"
        }
        let plural = count == 1 ? "" : "s"
        if let current = layout?.currentDesktop(for: display) {
            return "\(count) desktop\(plural), showing \(current)"
        }
        return "\(count) desktop\(plural)"
    }

    /// Shows one more column than macOS reports when a step already points past
    /// the end, so existing configs stay visible instead of silently clamped.
    func recountColumns() {
        var counts: [String: Int] = [:]
        for display in displays {
            let detected = detectedCount(display: display) ?? 0
            let highestUsed = profiles
                .flatMap(\.steps)
                .filter { targetDisplay(for: $0.step)?.uuid == display.uuid }
                .map { max(1, $0.step.desktop ?? 1) }
                .max() ?? 0
            let manual = columnCounts[display.uuid] ?? 0
            counts[display.uuid] = min(9, max(1, detected, highestUsed, manual))
        }
        columnCounts = counts
    }

    func addColumn(display: DisplayInfo) {
        columnCounts[display.uuid] = min(9, columnCount(display: display) + 1)
    }

    /// Only empty columns can go: removing one that holds apps would silently
    /// drop them from the profile.
    func canRemoveColumn(display: DisplayInfo, desktop: Int) -> Bool {
        guard columnCount(display: display) > 1, let profile = selectedProfile else { return false }
        return !profile.steps.contains {
            targetDisplay(for: $0.step)?.uuid == display.uuid && ($0.step.desktop ?? 1) == desktop
        }
    }

    func removeColumn(display: DisplayInfo, desktop: Int) {
        guard canRemoveColumn(display: display, desktop: desktop) else { return }
        columnCounts[display.uuid] = max(1, columnCount(display: display) - 1)
    }

    /// True when the board shows more columns than the desktop actually has.
    func columnCountExceedsDetected(display: DisplayInfo) -> Bool {
        guard let detected = detectedCount(display: display), detected > 0 else { return false }
        return columnCount(display: display) > detected
    }

    // MARK: - Steps

    func targetDisplay(for step: LaunchStep) -> DisplayInfo? {
        DisplayRegistry.resolve(step.display, in: displays)
    }

    func steps(in key: ColumnKey, of profile: ProfileItem) -> [StepItem] {
        profile.steps.filter {
            guard let display = targetDisplay(for: $0.step) else { return false }
            return display.uuid == key.displayUUID && ($0.step.desktop ?? 1) == key.desktop
        }
    }

    /// Steps pointing at a display that is not attached (or whose name changed),
    /// e.g. while editing the work profile at home.
    func orphanSteps(of profile: ProfileItem) -> [StepItem] {
        profile.steps.filter { targetDisplay(for: $0.step) == nil }
    }

    func add(app: InstalledApp, to key: ColumnKey) {
        guard let index = selectedIndex,
              let display = displays.first(where: { $0.uuid == key.displayUUID }) else { return }
        let token = app.bundleID ?? app.path
        let step = LaunchStep(
            app: token,
            display: CaptureService.selector(for: display, displays: displays),
            desktop: key.desktop,
            wait: nil,
            quitFirst: nil,
            note: nil
        )
        if profiles[index].steps.contains(where: { sameTarget($0.step, step) }) {
            status = "\(app.name) is already on \(display.name), desktop \(key.desktop)"
            return
        }
        let insertion = insertionIndex(for: key, in: index)
        profiles[index].steps.insert(StepItem(step), at: insertion)
        dirty = true
        status = "Added \(app.name) to \(display.name), desktop \(key.desktop)"
    }

    func addDroppedApp(at url: URL, to key: ColumnKey) {
        guard let app = AppInventory.app(atDroppedURL: url) else {
            errorMessage = "\"\(url.lastPathComponent)\" is not an app bundle.\nDrag an .app from Finder, or use the + button to pick from installed apps."
            return
        }
        add(app: app, to: key)
    }

    func moveStep(id: UUID, to key: ColumnKey) {
        guard let index = selectedIndex,
              let display = displays.first(where: { $0.uuid == key.displayUUID }),
              let current = profiles[index].steps.firstIndex(where: { $0.id == id }) else { return }
        var item = profiles[index].steps.remove(at: current)
        item.step.display = CaptureService.selector(for: display, displays: displays)
        item.step.desktop = key.desktop
        let insertion = insertionIndex(for: key, in: index)
        profiles[index].steps.insert(item, at: insertion)
        dirty = true
        status = "Moved \(appName(for: item.step.app)) to \(display.name), desktop \(key.desktop)"
    }

    func removeStep(id: UUID) {
        guard let index = selectedIndex,
              let position = profiles[index].steps.firstIndex(where: { $0.id == id }) else { return }
        let name = appName(for: profiles[index].steps[position].step.app)
        profiles[index].steps.remove(at: position)
        dirty = true
        status = "Removed \(name)"
    }

    func toggleQuitFirst(id: UUID) {
        guard let index = selectedIndex,
              let position = profiles[index].steps.firstIndex(where: { $0.id == id }) else { return }
        let inheriting = profiles[index].steps[position].step.quitFirst ?? defaults.resolvedQuitFirst
        profiles[index].steps[position].step.quitFirst = inheriting ? false : true
        dirty = true
    }

    func isQuitFirst(_ item: StepItem) -> Bool {
        item.step.quitFirst ?? defaults.resolvedQuitFirst
    }

    private func insertionIndex(for key: ColumnKey, in profileIndex: Int) -> Int {
        let steps = profiles[profileIndex].steps
        if let last = steps.lastIndex(where: {
            targetDisplay(for: $0.step)?.uuid == key.displayUUID && ($0.step.desktop ?? 1) == key.desktop
        }) {
            return last + 1
        }
        return steps.count
    }

    private func sameTarget(_ lhs: LaunchStep, _ rhs: LaunchStep) -> Bool {
        lhs.app == rhs.app
            && (lhs.display ?? "main") == (rhs.display ?? "main")
            && (lhs.desktop ?? 1) == (rhs.desktop ?? 1)
    }

    // MARK: - Drag and drop

    func handleDrop(providers: [NSItemProvider], at key: ColumnKey) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                    guard let url else { return }
                    Task { @MainActor in self?.addDroppedApp(at: url, to: key) }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                accepted = true
                provider.loadObject(ofClass: NSString.self) { [weak self] value, _ in
                    guard let text = value as? String else { return }
                    Task { @MainActor in self?.handleInternalDrop(text, at: key) }
                }
            }
        }
        return accepted
    }

    private func handleInternalDrop(_ text: String, at key: ColumnKey) {
        guard text.hasPrefix("step:"), let id = UUID(uuidString: String(text.dropFirst(5))) else { return }
        moveStep(id: id, to: key)
    }

    // MARK: - App metadata

    private func app(for token: String) -> ResolvedApp? {
        if let cached = resolvedApps[token] { return cached }
        guard let resolved = AppLauncher.resolve(token) else { return nil }
        resolvedApps[token] = resolved
        return resolved
    }

    func appName(for token: String) -> String {
        app(for: token)?.name ?? token
    }

    func icon(for token: String) -> NSImage? {
        icon(key: token) { self.app(for: token)?.url.path }
    }

    func icon(forPath path: String) -> NSImage {
        icon(key: "path:" + path) { path }
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
            ?? NSImage()
    }

    private func icon(key: String, path: () -> String?) -> NSImage? {
        if let cached = icons[key] { return cached }
        guard let path = path(), FileManager.default.fileExists(atPath: path) else { return nil }
        let image = AppInventory.icon(forFile: path)
        icons[key] = image
        return image
    }

    // MARK: - Installed apps

    func loadInstalledAppsIfNeeded(force: Bool = false) {
        guard force || (installedApps.isEmpty && !scanningApps) else { return }
        scanningApps = true
        Task.detached(priority: .userInitiated) {
            let found = AppInventory.scan()
            await MainActor.run {
                self.installedApps = found
                self.scanningApps = false
            }
        }
    }

    func filteredInstalledApps(query: String) -> [InstalledApp] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return installedApps }
        return installedApps.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || ($0.bundleID?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    func targetLabel(_ key: ColumnKey) -> String {
        let name = displays.first { $0.uuid == key.displayUUID }?.name ?? "display"
        return "\(name), desktop \(key.desktop)"
    }

    func displaySummary() -> String {
        let externals = displays.filter { !$0.isBuiltin }
        if externals.isEmpty {
            return displays.isEmpty ? "no displays detected" : "built-in display only"
        }
        return displays.map { $0.isBuiltin ? "built-in" : $0.name }.joined(separator: " + ")
    }

    // MARK: - Profile conditions

    func matches(_ profile: ProfileItem) -> Bool {
        Runner.matches(profile.when, displays: displays)
    }

    /// First match wins, exactly like the CLI, so this is the profile a bare
    /// `desk-launch` would run with the current displays.
    var activeProfileID: UUID? {
        profiles.first { Runner.matches($0.when, displays: displays) }?.id
    }

    func conditionSummary(_ profile: ProfileItem) -> String {
        guard let when = profile.when else { return "matches every setup" }
        if when.isCatchAll == true { return "fallback — matches any setup" }

        var parts: [String] = []
        if let value = when.externalName { parts.append("external named \"\(value)\"") }
        if let value = when.externalUUID { parts.append("external UUID \(value)") }
        if let value = when.externalModel { parts.append("external model \(value)") }
        if let value = when.externalVendor { parts.append("external vendor \(value)") }
        if let value = when.externalSerial { parts.append("external serial \(value)") }
        if let value = when.builtinPresent { parts.append(value ? "built-in attached" : "clamshell") }
        if let value = when.minExternal { parts.append("at least \(value) external") }
        if let value = when.maxExternal { parts.append("at most \(value) external") }
        if let value = when.anyExternal { parts.append(value ? "any external" : "no external") }
        return parts.isEmpty ? "matches every setup" : parts.joined(separator: ", ")
    }

    // MARK: - Saving

    func save() -> Bool {
        guard !profiles.isEmpty else {
            errorMessage = "Add at least one profile before saving."
            return false
        }
        let names = profiles.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        if names.contains(where: \.isEmpty) {
            errorMessage = "Every profile needs a name."
            return false
        }
        if Set(names.map { $0.lowercased() }).count != names.count {
            errorMessage = "Profile names must be unique."
            return false
        }
        do {
            let config = Configuration(defaults: defaults, profiles: profiles.map { $0.asProfile() })
            try ConfigStore.save(config, to: configPath)
            dirty = false
            status = "Saved \(configPath)"
            return true
        } catch {
            errorMessage = "Could not save \(configPath)\n\(error.localizedDescription)"
            return false
        }
    }

    func revert() {
        loadFromDisk()
        recountColumns()
        status = "Reverted to \(configPath)"
    }

    // MARK: - Running the CLI

    func run(dryRun: Bool) {
        guard !isRunning, let profile = selectedProfile else { return }
        guard save() else { return }
        guard let executable = Bundle.main.executableURL else {
            errorMessage = "Cannot locate the desk-launch executable."
            return
        }

        var arguments = ["--cli", "--config", configPath, "--profile", profile.name]
        if dryRun { arguments.append("--dry-run") }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        log = ""
        logVisible = true
        isRunning = true
        status = dryRun ? "Dry run…" : "Running \"\(profile.name)\"…"
        log = "$ desk-launch \(arguments.dropFirst().joined(separator: " "))\n\n"

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendLog(text) }
        }

        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                guard let self else { return }
                self.isRunning = false
                self.runningProcess = nil
                self.appendLog("\n— exit code \(finished.terminationStatus) —\n")
                self.status = finished.terminationStatus == 0
                    ? (dryRun ? "Dry run finished" : "Run finished")
                    : "Run failed with exit code \(finished.terminationStatus)"
            }
        }

        do {
            try process.run()
            runningProcess = process
        } catch {
            isRunning = false
            runningProcess = nil
            errorMessage = "Could not start desk-launch\n\(error.localizedDescription)"
        }
    }

    func stopRun() {
        runningProcess?.terminate()
    }

    private func appendLog(_ text: String) {
        log += text
        if log.count > 200_000 {
            log = String(log.suffix(150_000))
        }
    }


    // MARK: - System actions

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Asks macOS to register *this* app for Accessibility and show its prompt.
    /// This is what creates a permission entry that matches the running binary;
    /// toggling a stale entry by hand does not.
    func requestAccessibility(openSettings: Bool = false) {
        _ = SpacesService.accessibilityEnabled(prompt: true)
        refreshPermission()
        guard openSettings else { return }
        // Let the system prompt appear first; it offers the same destination.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if !self.accessibilityGranted { self.openAccessibilitySettings() }
        }
    }

    /// Cheap check, called when the app becomes active again so the banner
    /// clears the moment permission is granted instead of after a relaunch.
    func refreshPermission() {
        let granted = SpacesService.accessibilityEnabled(prompt: false)
        if granted != accessibilityGranted {
            accessibilityGranted = granted
        }
    }

    func revealConfigInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: configPath)])
    }
}
