import SwiftUI
import UniformTypeIdentifiers

/// "Servers" screen: list of saved configs, choosing the active one, deletion, import.
struct ConfigsView: View {
    let store: ConfigStore
    let pinger: Pinger
    @State private var showImport = false
    /// Config currently being renamed (nil — dialog closed), and the name draft.
    @State private var renaming: ServerConfig?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            Group {
                if store.configs.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Servers")
            .toolbar {
                ToolbarItem {
                    Button { showImport = true } label: {
                        Label("Import", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showImport) {
                ImportConfigView { config in store.add(config) }
            }
            // One-shot auto-ping when the tab opens: touches only servers not yet
            // pinged; reopening doesn't restart.
            .onAppear { pinger.pingAll(store.configs) }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No configs", systemImage: "tray")
        } description: {
            Text("Import a vpn:// link, WireGuard .conf or JSON.")
        } actions: {
            Button("Import") { showImport = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var list: some View {
        List {
            ForEach(store.configs) { config in
                row(for: config)
            }
        }
        // Rename dialog. TextField in an alert is supported since macOS 12.
        .alert("Rename server", isPresented: renamingActive) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let config = renaming { store.rename(config, to: renameText) }
                renaming = nil
            }
        } message: {
            Text("Enter a new name for this server.")
        }
    }

    @ViewBuilder
    private func row(for config: ServerConfig) -> some View {
        ConfigRow(
            config: config,
            isActive: config.id == store.activeID,
            pinger: pinger,
            onSelect: { store.setActive(config) },
            onDelete: { store.remove(config) },
            onRename: { startRename(config) }
        )
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { store.remove(config) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button { startRename(config) } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }

    private func startRename(_ config: ServerConfig) {
        renaming = config
        renameText = config.name
    }

    /// Bool wrapper over `renaming` for the alert's `isPresented:`.
    private var renamingActive: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }
}

private struct ConfigRow: View {
    let config: ServerConfig
    let isActive: Bool
    let pinger: Pinger
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onRename: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Choosing the active one — tapping the main part of the row.
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    Text(config.serverInfo.flag)
                        .font(.title2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(config.name)
                            .font(.headline)
                        Text(config.serverInfo.subtitle)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .help("Active server")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Ping the server — a separate button, doesn't interfere with selection.
            PingControl(config: config, pinger: pinger)

            // Delete — a separate button on the right.
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete config")
        }
        .padding(.vertical, 4)
        // Right-click on the row: rename / delete.
        .contextMenu {
            Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Import

private struct ImportConfigView: View {
    let onImport: (ServerConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var errorMessage: String?
    @State private var showFileImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import config")
                .font(.title2.bold())
            Text("Paste a vpn:// link, WireGuard .conf or JSON, or choose a file.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 170)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if text.isEmpty {
                        Text("vpn://... / [Interface]... / {...}")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("From file...") { showFileImporter = true }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { handleImport() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                text = contents
                errorMessage = nil
            } else {
                errorMessage = "Could not read the file."
            }
        }
    }

    private func handleImport() {
        do {
            let config = try ConfigParser.parse(text)
            onImport(config)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    // A List without an explicit size crashes the canvas preview on macOS 26.2
    // (NSHostingView.minSize → TableViewListCore assertion). Pin the size, like the
    // real window — in the app ConfigsView lives inside RootView's frame anyway.
    ConfigsView(store: ConfigStore(), pinger: Pinger())
        .frame(width: 420, height: 560)
}
