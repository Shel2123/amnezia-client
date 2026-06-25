import SwiftUI
import Observation

/// Measures latency to a server with a TCP probe to its endpoint port and caches the
/// result by config id. A single instance is shared between the server list and the
/// connection card, so a ping started in one tab is visible in the other.
@MainActor
@Observable
final class Pinger {
    enum Result: Equatable {
        case idle
        case pinging
        case success(ms: Int)
        case failed
    }

    private(set) var results: [ServerConfig.ID: Result] = [:]

    func result(for id: ServerConfig.ID) -> Result {
        results[id] ?? .idle
    }

    /// Auto-ping a set of configs. By default (`force == false`) touches only the
    /// not-yet-pinged (`.idle`) ones — so reopening a tab doesn't restart already
    /// measured servers (one-shot auto-ping per server).
    func pingAll(_ configs: [ServerConfig], force: Bool = false) {
        for config in configs where force || result(for: config.id) == .idle {
            ping(config)
        }
    }

    func ping(_ config: ServerConfig) {
        let id = config.id
        if result(for: id) == .pinging { return }   // measurement already running
        // No host:port to probe (non-WG config without a port) — nothing to ping.
        guard let target = config.pingTarget else {
            results[id] = .failed
            return
        }
        results[id] = .pinging
        Task { [weak self] in
            let ms = await Task.detached { Self.measure(host: target.host, port: target.port) }.value
            guard let self else { return }
            self.results[id] = ms.map { .success(ms: $0) } ?? .failed
        }
    }

    /// Latency to the server via a **TCP connect to the endpoint port**, NOT ICMP.
    /// Why not ICMP: VPN servers usually drop ICMP echo (100% loss) even though the
    /// tunnel works — an ICMP ping would falsely show "unreachable". A TCP SYN gets
    /// through: the server replies either SYN-ACK (port open) or RST (port closed for
    /// TCP — it's UDP) — both mean the host is reachable, and the time to reply = RTT.
    /// Timeout (neither SYN-ACK nor RST) = unreachable. Non-blocking connect + poll:
    /// accurate RTT without the overhead of spawning a process.
    nonisolated private static func measure(host: String, port: Int) -> Int? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let info else { return nil }
        defer { freeaddrinfo(info) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        // Non-blocking connect so we control the timeout ourselves.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let start = DispatchTime.now()
        if connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
            return elapsedMs(since: start)             // connected immediately
        }
        if errno != EINPROGRESS {
            // Immediate refusal: ECONNREFUSED = host replied RST → reachable.
            return errno == ECONNREFUSED ? elapsedMs(since: start) : nil
        }

        // Wait for the socket to become writable with a 2s timeout.
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 2000) > 0 else { return nil }   // timeout → unreachable

        // The connect result is in SO_ERROR: 0 = port open, ECONNREFUSED = port closed
        // but the host replied — both mean reachability.
        var soErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
        return (soErr == 0 || soErr == ECONNREFUSED) ? elapsedMs(since: start) : nil
    }

    nonisolated private static func elapsedMs(since start: DispatchTime) -> Int {
        let ns = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return max(1, Int((Double(ns) / 1_000_000).rounded()))
    }
}

/// Capsule "ping the server" button: a tap starts the measurement, the label shows the
/// result. Stateless itself — everything is held by the shared `Pinger` by config id,
/// so it works the same in a list row and in the connection card.
struct PingControl: View {
    let config: ServerConfig
    var pinger: Pinger

    private var result: Pinger.Result { pinger.result(for: config.id) }

    var body: some View {
        Button { pinger.ping(config) } label: {
            content
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tint.opacity(0.12), in: Capsule())
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .disabled(result == .pinging)
        .help("Ping server")
    }

    @ViewBuilder
    private var content: some View {
        switch result {
        case .idle:
            Label("Ping", systemImage: "speedometer")
        case .pinging:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Pinging...")
            }
        case .success(let ms):
            Label("\(ms) ms", systemImage: "wifi")
        case .failed:
            Label("No reply", systemImage: "wifi.slash")
        }
    }

    /// Green / yellow / orange by latency thresholds.
    private var tint: Color {
        switch result {
        case .success(let ms):
            switch ms {
            case ..<60:  return .green
            case ..<120: return .yellow
            default:     return .orange
            }
        case .failed:          return .red
        case .idle, .pinging:  return .gray
        }
    }
}
