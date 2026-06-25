import Foundation

/// Protocol / config type — for display and connection.
enum ConfigKind: String, Codable, Hashable {
    case wireguard   = "WireGuard"
    case amneziaWG   = "AmneziaWG"
    case openVPN     = "OpenVPN"
    case xray        = "XRay"
    case shadowSocks = "Shadowsocks"
    case unknown     = "VPN"

    var label: String { rawValue }
}

/// A saved server config. Holds the parsed fields for the UI plus the **raw text**
/// (`raw`), which is re-parsed when deriving the tunnel config or after a format change.
struct ServerConfig: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: Int?
    var kind: ConfigKind
    var countryCode: String?
    var raw: String
    /// Ready wg-quick text for bringing the tunnel up (WG/AWG). For an imported `.conf`
    /// it equals `raw`; for `vpn://`/JSON it's extracted from the nested
    /// `containers[].<proto>.last_config.config` with DNS placeholders substituted.
    /// `nil` — the config isn't tunneled by this slice (OpenVPN/XRay/…).
    var tunnelConf: String?
    var importedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int? = nil,
        kind: ConfigKind = .unknown,
        countryCode: String? = nil,
        raw: String,
        tunnelConf: String? = nil,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.kind = kind
        self.countryCode = countryCode
        self.raw = raw
        self.tunnelConf = tunnelConf
        self.importedAt = importedAt
    }

    var endpoint: String {
        if let port { return "\(host):\(port)" }
        return host
    }

    /// Target for ping — the real `Endpoint` host:port from wg-quick (the server the
    /// handshake goes to). We ping it with a TCP probe to this port: VPN servers usually
    /// silence ICMP but reply to TCP (RST), so it's an honest sign of reachability and
    /// latency. Falls back to the top-level host/port for non-WG configs; nil — no port,
    /// nothing to ping.
    var pingTarget: (host: String, port: Int)? {
        if let conf = tunnelConf, let hp = ConfigParser.endpointHostPort(in: conf) {
            return hp
        }
        if let port { return (host, port) }
        return nil
    }

    /// Maps to the Home card's display model.
    var serverInfo: ServerInfo {
        ServerInfo(
            name: name,
            subtitle: "\(endpoint) • \(kind.label)",
            countryCode: countryCode,
            pingMs: nil
        )
    }
}
