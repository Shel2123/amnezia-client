import SwiftUI
import AppKit

@main
struct AmneziaNativeSliceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Shared app state. Lives here so both the main window and the menu bar icon
    // (MenuBarExtra) observe the same tunnel/configs.
    @State private var store = ConfigStore()
    @State private var tunnel = AwgTunnel()
    @State private var pinger = Pinger()

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView(store: store, tunnel: tunnel, pinger: pinger)
        }
        .windowResizability(.contentSize)

        // Menu bar icon: sun when VPN is active, moon when off.
        MenuBarExtra {
            MenuBarContent(
                state: tunnel.state,
                serverName: store.active?.name,
                canToggle: usingTunnel,
                toggle: toggle
            )
        } label: {
            Image(systemName: tunnel.state == .connected ? "sun.max.fill" : "moon.fill")
        }
        .menuBarExtraStyle(.menu)
    }

    // The real tunnel is used only for a tunnelable (WireGuard/AmneziaWG) config.
    // Other protocols are not accepted by this slice.
    private var usingTunnel: Bool {
        store.active.map(WireGuardConfigBuilder.isTunnelable) ?? false
    }

    private func toggle() {
        guard usingTunnel, let config = store.active else { return }
        tunnel.toggle(config: config)
    }
}

/// On app termination (Cmd-Q, Quit from the menu bar) we synchronously bring the
/// tunnel down so the root daemon `amneziawg-go` does not linger as a zombie.
/// Closing the window alone does not terminate the app (it lives in the menu bar),
/// so the tunnel stays managed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        AwgTunnel.teardownSync()
    }
}
