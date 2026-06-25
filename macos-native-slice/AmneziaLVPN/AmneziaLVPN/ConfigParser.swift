import Foundation
import Compression

enum ConfigParseError: LocalizedError {
    case empty
    case unrecognized
    case decodeFailed
    case missingHost

    var errorDescription: String? {
        switch self {
        case .empty:        "Empty input."
        case .unrecognized: "Unrecognized format. Expected vpn://, WireGuard .conf or JSON."
        case .decodeFailed: "Could not decode the vpn:// link."
        case .missingHost:  "Config has no server address (hostName / Endpoint)."
        }
    }
}

/// AmneziaVPN config parser — a Swift port of the main paths of the real
/// `ImportController::extractConfigFromData`:
///   • `vpn://`        → base64url → Qt qUncompress → JSON
///   • WireGuard .conf → INI [Interface]/[Peer], Endpoint = host:port
///   • plain JSON      → { hostName, description, port, defaultContainer }
/// Other schemes (vless/vmess/trojan/ss) are out of scope for the UI slice.
enum ConfigParser {
    static func parse(_ input: String) throws -> ServerConfig {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ConfigParseError.empty }

        if text.hasPrefix("vpn://")   { return try parseAmneziaLink(text) }
        if text.contains("[Interface]") { return try parseWireGuard(text) }
        if text.hasPrefix("{")        { return try parseAmneziaJSON(text, raw: text) }
        throw ConfigParseError.unrecognized
    }

    // MARK: - vpn:// link

    private static func parseAmneziaLink(_ link: String) throws -> ServerConfig {
        let payload = String(link.dropFirst("vpn://".count))
        guard let compressed = Data(base64URLEncoded: payload) else {
            throw ConfigParseError.decodeFailed
        }
        guard let json = qUncompress(compressed) else {
            throw ConfigParseError.decodeFailed
        }
        let text = String(decoding: json, as: UTF8.self)
        // Keep raw as the original link — it's easier to carry around.
        return try parseAmneziaJSON(text, raw: link)
    }

    // MARK: - Amnezia JSON

    private static func parseAmneziaJSON(_ text: String, raw: String) throws -> ServerConfig {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ConfigParseError.unrecognized }

        guard let host = obj["hostName"] as? String, !host.isEmpty else {
            throw ConfigParseError.missingHost
        }
        let name = (obj["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host
        let kind = kind(fromContainer: obj["defaultContainer"] as? String)

        // Pull out the nested wg-quick config — without it a vpn:// link can't be
        // brought up into a tunnel (previously raw held the link itself → connect failed).
        let tunnelConf = extractWireGuardConf(from: obj)

        // Take the port from the nested config's Endpoint (more accurate than the
        // top-level one), otherwise from the top-level `port`.
        var port = obj["port"] as? Int
        if let conf = tunnelConf,
           let endpoint = iniValue("Endpoint", in: conf) {
            let (_, p) = splitHostPort(endpoint)
            if let p { port = p }
        }

        return ServerConfig(name: name, host: host, port: port, kind: kind,
                            raw: raw, tunnelConf: tunnelConf)
    }

    /// Extracts the ready wg-quick text from Amnezia JSON: finds the container
    /// (priority — `defaultContainer`), takes `<proto>.last_config.config` and
    /// substitutes the DNS placeholders. Returns nil if there's no WG/AWG container.
    private static func extractWireGuardConf(from obj: [String: Any]) -> String? {
        guard let containers = obj["containers"] as? [[String: Any]] else { return nil }
        let preferred = obj["defaultContainer"] as? String
        // defaultContainer first, the rest after (stable).
        let ordered = containers.enumerated().sorted { lhs, rhs in
            let l = (lhs.element["container"] as? String) == preferred
            let r = (rhs.element["container"] as? String) == preferred
            if l != r { return l }
            return lhs.offset < rhs.offset
        }.map(\.element)

        for container in ordered {
            for (key, value) in container {
                guard key != "container",
                      let block = value as? [String: Any],
                      let lastConfig = block["last_config"] as? String,
                      let lcData = lastConfig.data(using: .utf8),
                      let lc = try? JSONSerialization.jsonObject(with: lcData) as? [String: Any],
                      let configText = lc["config"] as? String,
                      configText.contains("[Interface]")   // wg-quick only (WG/AWG)
                else { continue }
                return substituteDNS(configText, obj: obj)
            }
        }
        return nil
    }

    /// `$PRIMARY_DNS` / `$SECONDARY_DNS` → `dns1` / `dns2` from JSON (as in
    /// `ConfiguratorBase::applyDnsToNativeConfig`); default — Cloudflare.
    private static func substituteDNS(_ text: String, obj: [String: Any]) -> String {
        let d1 = (obj["dns1"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "1.1.1.1"
        let d2 = (obj["dns2"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "1.0.0.1"
        return text
            .replacingOccurrences(of: "$PRIMARY_DNS", with: d1)
            .replacingOccurrences(of: "$SECONDARY_DNS", with: d2)
    }

    /// `Endpoint = host:port` from the wg-quick text — the real server and port the
    /// handshake goes to. Needed for ping (a TCP probe to this host:port).
    static func endpointHostPort(in wgQuick: String) -> (host: String, port: Int)? {
        guard let endpoint = iniValue("Endpoint", in: wgQuick) else { return nil }
        let (host, port) = splitHostPort(endpoint)
        guard !host.isEmpty, let port else { return nil }
        return (host, port)
    }

    /// Value of `Key = value` from the wg-quick text (first occurrence).
    private static func iniValue(_ key: String, in text: String) -> String? {
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = line.components(separatedBy: " = ")
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func kind(fromContainer container: String?) -> ConfigKind {
        guard let c = container?.lowercased() else { return .unknown }
        if c.contains("awg")          { return .amneziaWG }
        if c.contains("wireguard")    { return .wireguard }
        if c.contains("openvpn")      { return .openVPN }
        if c.contains("xray")         { return .xray }
        if c.contains("shadowsocks")  { return .shadowSocks }
        return .unknown
    }

    // MARK: - WireGuard .conf (INI)

    private static func parseWireGuard(_ text: String) throws -> ServerConfig {
        var map: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("[") || line.hasPrefix("#") { continue }
            let parts = line.components(separatedBy: " = ")
            guard parts.count == 2 else { continue }
            map[parts[0].trimmingCharacters(in: .whitespaces)] =
                parts[1].trimmingCharacters(in: .whitespaces)
        }

        guard let endpoint = map["Endpoint"], !endpoint.isEmpty else {
            throw ConfigParseError.missingHost
        }
        let (host, port) = splitHostPort(endpoint)
        guard !host.isEmpty else { throw ConfigParseError.missingHost }

        // AmneziaWG differs from plain WireGuard by having obfuscation (Jc/Jmin/...).
        let kind: ConfigKind = map.keys.contains(where: { $0.hasPrefix("J") || $0.hasPrefix("S") || $0.hasPrefix("H") })
            ? .amneziaWG : .wireguard

        return ServerConfig(name: host, host: host, port: port, kind: kind,
                            raw: text, tunnelConf: text)
    }

    /// host:port, with IPv6 in brackets `[::1]:51820` supported.
    private static func splitHostPort(_ s: String) -> (host: String, port: Int?) {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            let port = rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil
            return (host, port)
        }
        if let colon = s.lastIndex(of: ":") {
            return (String(s[..<colon]), Int(s[s.index(after: colon)...]))
        }
        return (s, nil)
    }

    // MARK: - Qt qUncompress

    /// Qt `qCompress` lays out `[4-byte BE uncompressed size][zlib stream]`.
    /// `Compression.COMPRESSION_ZLIB` is **raw DEFLATE** (RFC 1951), so we strip the
    /// 4 size bytes + 2 zlib header bytes + 4 adler32 bytes at the tail.
    static func qUncompress(_ data: Data) -> Data? {
        guard data.count > 10 else { return nil }
        let expected =
            (Int(data[data.startIndex])     << 24) |
            (Int(data[data.startIndex + 1]) << 16) |
            (Int(data[data.startIndex + 2]) << 8)  |
             Int(data[data.startIndex + 3])
        let zlib = data.subdata(in: data.index(data.startIndex, offsetBy: 4)..<data.endIndex)
        guard zlib.count > 6 else { return nil }
        let raw = zlib.subdata(in: zlib.index(zlib.startIndex, offsetBy: 2)..<zlib.index(zlib.endIndex, offsetBy: -4))

        let capacity = max(expected, raw.count * 4 + 1024)
        var dst = Data(count: capacity)
        let written = dst.withUnsafeMutableBytes { dstBuf -> Int in
            raw.withUnsafeBytes { srcBuf -> Int in
                guard let dp = dstBuf.bindMemory(to: UInt8.self).baseAddress,
                      let sp = srcBuf.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(dp, capacity, sp, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return dst.prefix(written)
    }
}

private extension Data {
    /// base64url (Qt `Base64UrlEncoding | OmitTrailingEquals`) → Data.
    init?(base64URLEncoded s: String) {
        var str = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 { str.append("=") }
        self.init(base64Encoded: str)
    }
}
