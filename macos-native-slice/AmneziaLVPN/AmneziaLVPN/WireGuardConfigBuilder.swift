import Foundation

/// Prepares a wg-quick config for the tunnel from a `ServerConfig`.
///
/// An imported WireGuard/AmneziaWG `.conf` is already in wg-quick format — returned
/// as-is. Other sources (vpn:// → Amnezia JSON with containers, OpenVPN, XRay) aren't
/// expanded into a tunnel yet: they need either parsing of the nested `lastConfig` or a
/// different backend. Returning nil = "this config isn't tunnelable yet".
enum WireGuardConfigBuilder {
    static func wgQuick(from config: ServerConfig) -> String? {
        // The parser already expands a vpn:// link/JSON into ready wg-quick text (with
        // DNS substituted) and puts it in `tunnelConf`. For an imported `.conf` it
        // equals raw. Fall back to raw for configs saved by an old version without the
        // tunnelConf field.
        if let conf = config.tunnelConf, conf.contains("[Interface]") {
            return conf
        }
        switch config.kind {
        case .wireguard, .amneziaWG:
            return config.raw.contains("[Interface]") ? config.raw : nil
        default:
            return nil
        }
    }

    /// Whether this config can be brought up as a real tunnel right now.
    static func isTunnelable(_ config: ServerConfig) -> Bool {
        wgQuick(from: config) != nil
    }
}
