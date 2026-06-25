import SwiftUI

/// Home/Connection screen of the slice. For a tunnelable config (WireGuard/
/// AmneziaWG) the button drives the real VPN through `AwgTunnel`. Any other
/// protocol is not accepted: the screen shows a message and the button is disabled.
struct ContentView: View {
    /// Active config from the shared `ConfigStore`.
    var activeConfig: ServerConfig? = nil
    var serverInfo: ServerInfo? = nil
    /// Real VPN driver (shared, from App).
    var tunnel: AwgTunnel
    /// Shared ping service (from App), used by the selected server's card.
    var pinger: Pinger

    /// The real tunnel is used only if the active config is tunnelable.
    private var usingTunnel: Bool {
        activeConfig.map(WireGuardConfigBuilder.isTunnelable) ?? false
    }

    private var state: ConnectionState { usingTunnel ? tunnel.state : .disconnected }
    private var connectedSince: Date? { usingTunnel ? tunnel.connectedSince : nil }

    /// Shown when an active config exists but cannot be tunneled by this slice.
    private var unsupportedMessage: String? {
        guard activeConfig != nil, !usingTunnel else { return nil }
        return "This protocol is not accepted."
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            ConnectionStatusView(state: state, connectedSince: connectedSince)

            Spacer()

            ServerInfoCard(server: serverInfo, config: activeConfig, pinger: pinger)

            if let message = usingTunnel ? tunnel.errorText : unsupportedMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            ConnectButton(state: state, isDisabled: !usingTunnel, action: toggle)
        }
        .frame(maxHeight: .infinity)
        .padding(32)
        .frame(maxWidth: 420)
        .animation(.snappy, value: state)
    }

    private func toggle() {
        guard usingTunnel, let config = activeConfig else { return }
        tunnel.toggle(config: config)
    }
}

// MARK: - Status

private struct ConnectionStatusView: View {
    let state: ConnectionState
    let connectedSince: Date?

    var body: some View {
        VStack(spacing: 14) {
            StatusOrb(state: state)

            Text(state.label)
                .font(.title3.weight(.semibold))

            durationLabel
        }
    }

    /// Real session duration — counted on the Swift side from the moment of the
    /// transition to `.connected`. `TimelineView` ticks once a second without timers.
    @ViewBuilder
    private var durationLabel: some View {
        if state == .connected, let connectedSince {
            TimelineView(.periodic(from: connectedSince, by: 1)) { context in
                Text(Self.elapsed(from: connectedSince, to: context.date))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else {
            // Reserve the line so the layout doesn't jump between states.
            Text(" ").font(.callout)
        }
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Sky status indicator

/// Animated indicator: a blue crescent (disconnected) → gathers into a circle
/// (connecting) → lights up as a sun with growing rays (connected).
/// Reconnecting behaves like connecting, disconnecting — the reverse path.
private struct StatusOrb: View {
    let state: ConnectionState

    private var isConnected: Bool { state == .connected }
    private var isWorking: Bool {
        state == .connecting || state == .reconnecting || state == .disconnecting
    }

    /// 0 — crescent (half-moon), 1 — full circle. Crescent only at rest (disconnected).
    private var phase: CGFloat { state == .disconnected ? 0 : 1 }
    /// Sun rays grow only when connected.
    private var rays: CGFloat { isConnected ? 1 : 0 }

    /// Color of the sky body: blue crescent → solar gold.
    private var bodyColor: Color {
        switch state {
        case .disconnected:                 Color(red: 0.46, green: 0.73, blue: 1.0)
        case .connected:                    Color(red: 1.0, green: 0.76, blue: 0.23)
        case .connecting, .reconnecting,
             .disconnecting:                Color(red: 0.62, green: 0.7, blue: 0.95)
        }
    }

    var body: some View {
        ZStack {
            // Warm glow — brighter when the "sun" is lit.
            Circle()
                .fill(bodyColor)
                .frame(width: 104, height: 104)
                .blur(radius: 38)
                .opacity(isConnected ? 0.6 : 0.22)

            // Sun rays (behind the body), growing from under the disc.
            SunRays(scale: rays, color: bodyColor)

            // Sky body: crescent ↔ circle (eo-fill + clip to a circle so the "cutting"
            // circle doesn't poke past the disc in the circle phase).
            Crescent(phase: phase)
                .fill(bodyColor, style: FillStyle(eoFill: true))
                .frame(width: 104, height: 104)
                .clipShape(Circle())
                .shadow(color: bodyColor.opacity(0.55), radius: isConnected ? 14 : 7)

            // Rotating progress arc while a transition is in progress.
            if isWorking {
                WorkingRing(color: bodyColor)
                    .frame(width: 122, height: 122)
            }
        }
        .frame(width: 184, height: 184)
        .animation(.smooth(duration: 0.55), value: state)
        .animation(.spring(response: 0.55, dampingFraction: 0.55), value: rays)
    }
}

/// A crescent as the difference of two circles (even-odd). `phase` 0 → the cutting
/// circle is close (thin crescent), 1 → moves away (full circle). The morph between
/// them = "the moon gathers into a circle".
private struct Crescent: Shape {
    var phase: CGFloat
    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        // The cutting circle shifts right: 0.85r (crescent) → far away (no cut → full
        // circle).
        let off = r * (0.85 + phase * 2.8)
        p.addEllipse(in: CGRect(x: c.x + off - r, y: c.y - r, width: 2 * r, height: 2 * r))
        return p
    }
}

/// Sun rays: a set of capsules around a circle, growing outward with `scale`
/// (0 → no rays).
private struct SunRays: View {
    var scale: CGFloat
    var color: Color
    private let count = 12
    private let inner: CGFloat = 60
    private let maxLen: CGFloat = 22

    var body: some View {
        ZStack {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 5, height: max(0.001, maxLen * scale))
                    // The inner end is fixed at `inner`, the ray grows outward.
                    .offset(y: -(inner + maxLen * scale / 2))
                    .rotationEffect(.degrees(Double(i) / Double(count) * 360))
            }
        }
        .opacity(Double(min(1, scale * 1.5)))
    }
}

/// An infinitely rotating arc — an activity indicator during a transition.
private struct WorkingRing: View {
    let color: Color
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            .rotationEffect(.degrees(spin ? 360 : 0))
            .opacity(0.9)
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    spin = true
                }
            }
    }
}

// MARK: - Server card

private struct ServerInfoCard: View {
    let server: ServerInfo?
    /// Active config behind the card — drives the ping button. nil → no server.
    let config: ServerConfig?
    var pinger: Pinger

    var body: some View {
        GroupBox {
            if let server {
                HStack(spacing: 12) {
                    Text(server.flag)
                        .font(.system(size: 30))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name)
                            .font(.headline)
                        Text(server.subtitle)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    if let config {
                        PingControl(config: config, pinger: pinger)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Label("No server selected", systemImage: "tray")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Button

private struct ConnectButton: View {
    let state: ConnectionState
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if state.isTransitioning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(state.actionTitle)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(state == .connected || state == .reconnecting ? .red : .accentColor)
        // Disabled while the engine is busy (it ignores toggle), or when the active
        // config cannot be tunneled. Not disabled while reconnecting: the button
        // cancels the auto-reconnect.
        .disabled(state.isBusy || isDisabled)
    }
}

#Preview {
    ContentView(serverInfo: .sample, tunnel: AwgTunnel(), pinger: Pinger())
}
