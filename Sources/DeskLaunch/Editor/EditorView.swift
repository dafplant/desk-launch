import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HSplitView {
            ProfileSidebar(model: model)
                .frame(minWidth: 210, idealWidth: 245, maxWidth: 330)

            VStack(spacing: 0) {
                if let index = model.selectedIndex {
                    ProfileEditor(model: model, index: index)
                } else {
                    EmptyEditor(model: model)
                }
                Divider()
                StatusBar(model: model)
            }
            .frame(minWidth: 680, minHeight: 520)
        }
        .frame(minWidth: 940, minHeight: 600)
        .sheet(item: $model.browserTarget) { key in
            AppBrowserSheet(model: model, target: key)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            actions: {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            },
            message: {
                Text(model.errorMessage ?? "")
            }
        )
    }
}

// MARK: - Sidebar

private struct ProfileSidebar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Profiles")
                    .font(.headline)
                Spacer()
                Button {
                    model.newProfile()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New profile for the displays connected now")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            List(selection: $model.selection) {
                ForEach(model.profiles) { profile in
                    ProfileRow(model: model, profile: profile)
                        .tag(profile.id)
                }
            }
            .listStyle(.sidebar)

            Divider()
            DisplayFooter(model: model)
        }
    }
}

private struct ProfileRow: View {
    @ObservedObject var model: EditorModel
    let profile: EditorModel.ProfileItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(profile.name.isEmpty ? "Untitled" : profile.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if model.activeProfileID == profile.id {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                        .help("This profile runs on the displays connected now")
                }
            }
            HStack(spacing: 4) {
                if profile.when?.isCatchAll == true {
                    Text("fallback")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                }
                Text("\(profile.steps.count) app\(profile.steps.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DisplayFooter: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Displays")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.refreshSystem()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Re-read displays, desktops and permissions")
            }

            ForEach(model.displays, id: \.uuid) { display in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(display.name)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    Text(model.detectedLabel(display: display))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if !model.accessibilityGranted {
                Button {
                    model.requestAccessibility(openSettings: true)
                } label: {
                    Label("Grant Accessibility", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
                .help("Switching desktops needs Accessibility permission for this app")
            }

            if !model.disabledShortcuts.isEmpty {
                Text("Ctrl+\(model.disabledShortcuts.map(String.init).joined(separator: ", ")) is disabled")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("Mission Control's Switch to Desktop shortcuts are off for these desktops")
            }
        }
        .padding(12)
    }
}

// MARK: - Editor

private struct EmptyEditor: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No profiles yet")
                .font(.title3)
            Text("A profile is one arrangement of apps for one display setup.\nCreate one from the displays connected now, then drag apps onto desktops.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Create a profile") { model.newProfile() }
                .buttonStyle(.borderedProminent)
                .disabled(model.displays.isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct ProfileEditor: View {
    @ObservedObject var model: EditorModel
    let index: Int

    private var profileID: UUID? {
        model.profile(at: index)?.id
    }

    var body: some View {
        if let profileID {
            VStack(spacing: 0) {
                ProfileHeader(model: model, profileID: profileID)
                Divider()
                Board(model: model, profileID: profileID)
            }
        } else {
            EmptyView()
        }
    }
}

private struct ProfileHeader: View {
    @ObservedObject var model: EditorModel
    let profileID: UUID

    var body: some View {
        if let profile = model.profile(id: profileID) {
            content(for: profile)
        }
    }

    private func content(for profile: EditorModel.ProfileItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    TextField("Profile name", text: model.nameBinding(for: profile.id))
                        .textFieldStyle(.roundedBorder)
                        .font(.headline)
                        .frame(width: 280)
                    TextField("Description (optional)", text: model.descriptionBinding(for: profile.id))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(width: 380)
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    Button {
                        _ = model.save()
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!model.dirty)
                    .keyboardShortcut("s", modifiers: .command)
                    .help("Write the config file (⌘S)")

                    Button {
                        model.run(dryRun: true)
                    } label: {
                        Label("Dry run", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(model.isRunning)
                    .help("Print the plan without touching anything")

                    if model.isRunning {
                        Button {
                            model.stopRun()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                    } else {
                        Button {
                            model.run(dryRun: false)
                        } label: {
                            Label("Run", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("r", modifiers: .command)
                        .help("Run this profile (⌘R)")
                    }
                }
                .fixedSize()
            }

            HStack(spacing: 6) {
                Image(systemName: model.matches(profile) ? "checkmark.seal.fill" : "seal")
                    .font(.caption)
                    .foregroundStyle(model.matches(profile) ? Color.green : Color.secondary)
                Text(model.conditionSummary(profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help("The `when` block: which display setups select this profile")

                Spacer(minLength: 8)

                Menu {
                    Button("Use the displays connected now") { model.rebindConditionToCurrentSetup() }
                    Button("Match any setup (catch-all)") { model.makeCatchAll() }
                    Divider()
                    Button("Move up") { model.moveSelected(up: true) }
                        .disabled(!model.canMoveSelected(up: true))
                    Button("Move down") { model.moveSelected(up: false) }
                        .disabled(!model.canMoveSelected(up: false))
                    Divider()
                    Button("Duplicate profile") { model.duplicateSelected() }
                    Button("Delete profile") { model.deleteSelected() }
                        .disabled(model.profiles.count <= 1)
                } label: {
                    Label("Setup", systemImage: "slider.horizontal.3")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct Board: View {
    @ObservedObject var model: EditorModel
    let profileID: UUID

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !model.accessibilityGranted {
                    WarningRow(
                        text: "Accessibility is not granted, so switching desktops will fail. If the app is already switched on in System Settings, that grant belongs to an older build — reset it and grant again (see the README).",
                        actionTitle: "Grant access",
                        action: { model.requestAccessibility(openSettings: true) }
                    )
                }

                ForEach(model.displays, id: \.uuid) { display in
                    DisplayLane(model: model, profileID: profileID, display: display)
                }

                if let profile = model.profile(id: profileID) {
                    let orphans = model.orphanSteps(of: profile)
                    if !orphans.isEmpty {
                        OrphanLane(model: model, steps: orphans)
                    }
                }

                if model.displays.isEmpty {
                    Text("No displays detected. Connect a display and press refresh.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }
}

private struct WarningRow: View {
    let text: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(actionTitle, action: action)
                .font(.caption)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}

// MARK: - A display and its desktops

private struct DisplayLane: View {
    @ObservedObject var model: EditorModel
    let profileID: UUID
    let display: DisplayInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(display.name)
                    .font(.headline)
                Text(display.isMain ? "main" : "external")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Text(model.detectedLabel(display: display))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    model.addColumn(display: display)
                } label: {
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(model.columnCount(display: display) >= 9)
                .help("Show one more desktop column")
            }

            if model.columnCountExceedsDetected(display: display) {
                Text("This board shows more desktops than macOS reports — the extra columns only hold apps for later; a run will clamp them to the last real desktop.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(1...model.columnCount(display: display), id: \.self) { desktop in
                        DesktopColumn(model: model, profileID: profileID, display: display, desktop: desktop)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }
}

private struct DesktopColumn: View {
    @ObservedObject var model: EditorModel
    let profileID: UUID
    let display: DisplayInfo
    let desktop: Int

    @State private var isTargeted = false

    private var key: EditorModel.ColumnKey {
        EditorModel.ColumnKey(displayUUID: display.uuid, desktop: desktop)
    }

    var body: some View {
        let steps = model.profile(id: profileID).map { model.steps(in: key, of: $0) } ?? []

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Desktop \(desktop)")
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 4)
                Text("\(steps.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button {
                    model.browserTarget = key
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.borderless)
                .help("Add an app to \(model.targetLabel(key))")
            }

            if steps.isEmpty {
                Text("Drop an app here")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 46)
            } else {
                ForEach(steps) { item in
                    StepTile(model: model, item: item)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(width: 205, alignment: .top)
        .frame(minHeight: 132, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.22), lineWidth: isTargeted ? 2 : 1)
        )
        .onDrop(of: [UTType.fileURL, UTType.plainText], isTargeted: $isTargeted) { providers in
            model.handleDrop(providers: providers, at: key)
        }
        .contextMenu {
            Button("Add an app…") { model.browserTarget = key }
            if model.canRemoveColumn(display: display, desktop: desktop) {
                Divider()
                Button("Remove this empty column") {
                    model.removeColumn(display: display, desktop: desktop)
                }
            }
        }
    }
}

private struct StepTile: View {
    @ObservedObject var model: EditorModel
    let item: EditorModel.StepItem

    var body: some View {
        HStack(spacing: 7) {
            AppIconView(image: model.icon(for: item.step.app))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.appName(for: item.step.app))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if model.isQuitFirst(item) {
                    Text("relaunches each run")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button {
                model.removeStep(id: item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove from this desktop")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
        .onDrag {
            NSItemProvider(object: "step:\(item.id.uuidString)" as NSString)
        }
        .contextMenu {
            Toggle(
                "Quit the app first",
                isOn: Binding(
                    get: { model.isQuitFirst(item) },
                    set: { _ in model.toggleQuitFirst(id: item.id) }
                )
            )
            Divider()
            Button("Remove") { model.removeStep(id: item.id) }
        }
        .help(item.step.app)
    }
}

/// Steps that point at a display which is not attached right now. They are kept
/// as-is; dragging one into a column rebinds it to that display.
private struct OrphanLane: View {
    @ObservedObject var model: EditorModel
    let steps: [EditorModel.StepItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "questionmark.square.dashed")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                Text("Steps for a display that isn't connected")
                    .font(.headline)
            }
            Text("These are kept exactly as written. To rebind one to a connected display, drag it onto that desktop.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 10) {
                ForEach(steps) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            AppIconView(image: model.icon(for: item.step.app))
                            Text(model.appName(for: item.step.app))
                                .font(.system(size: 11, weight: .medium))
                            Button {
                                model.removeStep(id: item.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                        Text("\(item.step.display ?? "main"), desktop \(item.step.desktop ?? 1)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
                    .onDrag {
                        NSItemProvider(object: "step:\(item.id.uuidString)" as NSString)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.orange.opacity(0.08)))
    }
}

// MARK: - Shared bits

struct AppIconView: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .padding(3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
    }
}

private struct StatusBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            if model.logVisible {
                VStack(spacing: 0) {
                    HStack {
                        Text("Output")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Spacer()
                        Button {
                            model.logVisible = false
                        } label: {
                            Image(systemName: "xmark").font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)

                    ScrollView {
                        Text(model.log.isEmpty ? "No output yet." : model.log)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(height: 150)
                    .background(Color(nsColor: .textBackgroundColor))
                }
                Divider()
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(model.dirty ? Color.orange : Color.green)
                    .frame(width: 7, height: 7)
                Text(model.status.isEmpty ? (model.dirty ? "Unsaved changes" : "Saved") : model.status)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    model.logVisible.toggle()
                } label: {
                    Label(model.logVisible ? "Hide output" : "Show output", systemImage: "terminal")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                Button {
                    model.revealConfigInFinder()
                } label: {
                    Image(systemName: "folder").font(.caption)
                }
                .buttonStyle(.borderless)
                .help(model.configPath)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}
