import SwiftUI

/// App root: a shared `ConfigStore` and two tabs - "Connection" (Home) and
/// "Servers" (config list/import). The active config from the store is passed into
/// the Home card.
struct RootView: View {
    let store: ConfigStore
    let tunnel: AwgTunnel
    let pinger: Pinger

    var body: some View {
        TabView {
            ContentView(
                activeConfig: store.active,
                serverInfo: store.activeServerInfo,
                tunnel: tunnel,
                pinger: pinger
            )
            .tabItem { Label("Connection", systemImage: "power") }

            ConfigsView(store: store, pinger: pinger)
                .tabItem { Label("Servers", systemImage: "server.rack") }
        }
        .frame(width: 420, height: 560)
        // One-shot auto-ping of all servers at app launch.
        .task { pinger.pingAll(store.configs) }
    }
}

#Preview {
    RootView(store: ConfigStore(), tunnel: AwgTunnel(), pinger: Pinger())
}
