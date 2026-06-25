import Foundation

/// Display model of a server for the Home card. Built from the active `ServerConfig`
/// (see `ServerConfig.serverInfo`). Fields are optional: an imported config has neither
/// a country nor a ping until the real engine provides them.
struct ServerInfo: Hashable {
    let name: String
    /// "host:port • protocol"
    let subtitle: String
    /// ISO-3166 alpha-2, e.g. "NL". nil → globe.
    let countryCode: String?
    /// Ping in ms; nil if unknown (imported config).
    let pingMs: Int?

    /// Regional indicator symbols from the country code → emoji flag.
    var flag: String {
        guard let cc = countryCode, cc.count == 2 else { return "🌐" }
        let base: UInt32 = 127397 // 0x1F1E6 - 'A'
        var result = ""
        for scalar in cc.uppercased().unicodeScalars {
            guard ("A"..."Z").contains(Character(scalar)),
                  let regional = Unicode.Scalar(base + scalar.value)
            else { return "🌐" }
            result.unicodeScalars.append(regional)
        }
        return result
    }

    static let sample = ServerInfo(
        name: "Amnezia • Amsterdam",
        subtitle: "51.158.143.10:51820 • WireGuard",
        countryCode: "NL",
        pingMs: 38
    )
}
