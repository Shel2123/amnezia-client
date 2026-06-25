import SwiftUI

/// UI-level connection state, set by `AwgTunnel`. Owns labels, action titles, system
/// images, tint colors and transition flags in one place — a rich wrapper for the View.
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    /// The connection was up but dropped (stale handshake / sleep / network change) —
    /// the driver brings the tunnel back up with backoff. Unlike `.connecting`, the
    /// button is NOT disabled: the user can cancel the reconnect.
    case reconnecting

    /// Animation/spinner is shown: for all transitional phases, including auto-reconnect.
    var isTransitioning: Bool {
        self == .connecting || self == .disconnecting || self == .reconnecting
    }

    /// The engine is busy with a transition and ignores toggle — disable the button.
    /// Unlike `isTransitioning`, does NOT include `.reconnecting`: it can be cancelled
    /// manually.
    var isBusy: Bool {
        self == .connecting || self == .disconnecting
    }

    var label: String {
        switch self {
        case .disconnected:  "Disconnected"
        case .connecting:    "Connecting..."
        case .connected:     "Connected"
        case .disconnecting: "Disconnecting..."
        case .reconnecting:  "Reconnecting..."
        }
    }

    /// Title of the main button for the current state.
    var actionTitle: String {
        switch self {
        case .disconnected:  "Connect"
        case .connecting:    "Connecting..."
        case .connected:     "Disconnect"
        case .disconnecting: "Disconnecting..."
        // While reconnecting the button cancels it.
        case .reconnecting:  "Disconnect"
        }
    }

    var systemImage: String {
        switch self {
        case .disconnected:  "lock.open"
        case .connecting:    "lock.rotation"
        case .connected:     "lock.shield.fill"
        case .disconnecting: "lock.rotation"
        case .reconnecting:  "arrow.triangle.2.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .connected:     .yellow
        case .connecting:    .orange
        case .disconnecting: .orange
        case .reconnecting:  .orange
        case .disconnected:  .blue
        }
    }
}
