import AppKit
import SwiftUI

struct AppBrowserSheet: View {
    @ObservedObject var model: EditorModel
    let target: EditorModel.ColumnKey

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add an app")
                        .font(.headline)
                    Text(model.targetLabel(target))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search installed apps", text: $query)
                    .textFieldStyle(.plain)
                if model.scanningApps {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()

            if model.installedApps.isEmpty && !model.scanningApps {
                VStack(spacing: 8) {
                    Text("No apps found in the usual folders.")
                        .foregroundStyle(.secondary)
                    Text("Drag an .app from Finder onto a desktop column instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { app in
                    AppBrowserRow(model: model, app: app) {
                        add(app)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 580, height: 480)
        .onAppear { model.loadInstalledAppsIfNeeded() }
    }

    private var filtered: [InstalledApp] {
        model.filteredInstalledApps(query: query)
    }

    private func add(_ app: InstalledApp) {
        model.add(app: app, to: target)
        dismiss()
    }
}

private struct AppBrowserRow: View {
    @ObservedObject var model: EditorModel
    let app: InstalledApp
    let add: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            AppIconView(image: model.icon(forPath: app.path))
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                Text(app.bundleID ?? app.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Add", action: add)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: add)
        .help(app.path)
    }
}
