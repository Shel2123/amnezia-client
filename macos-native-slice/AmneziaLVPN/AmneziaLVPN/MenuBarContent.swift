import SwiftUI

/// Menu bar dropdown: current status, active server, quick connect/disconnect,
/// open the window and quit.
struct MenuBarContent: View {
    let state: ConnectionState
    let serverName: String?
    /// Whether the active config can be tunneled (otherwise the toggle is disabled).
    var canToggle: Bool = true
    let toggle: () -> Void

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Status (no button, just a line).
        Text(statusLine)

        if let serverName {
            Text("Server: \(serverName)")
        }

        Divider()

        Button(state.actionTitle, action: toggle)
            .disabled(state.isBusy || serverName == nil || !canToggle)

        Divider()

        Button("Open AmneziaLVPN") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch state {
        case .connected:     "VPN on"
        case .connecting:    "Connecting..."
        case .disconnecting: "Disconnecting..."
        case .disconnected:  "VPN off"
        case .reconnecting:  "Reconnecting..."
        }
    }
}
