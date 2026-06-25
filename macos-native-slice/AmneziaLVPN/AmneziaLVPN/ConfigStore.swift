import Foundation
import Observation

/// Config store: list, active config, persistence to disk (Application Support).
/// This is the data source for the Home card (`activeServerInfo`) and supplies the
/// active config to the tunnel driver.
@MainActor
@Observable
final class ConfigStore {
    private(set) var configs: [ServerConfig] = []
    private(set) var activeID: ServerConfig.ID?

    init() { load() }

    var active: ServerConfig? {
        configs.first { $0.id == activeID }
    }

    var activeServerInfo: ServerInfo? {
        active?.serverInfo
    }

    func add(_ config: ServerConfig) {
        configs.append(config)
        if activeID == nil { activeID = config.id } // first imported one becomes active
        persist()
    }

    func remove(_ config: ServerConfig) {
        configs.removeAll { $0.id == config.id }
        if activeID == config.id { activeID = configs.first?.id }
        persist()
    }

    func setActive(_ config: ServerConfig) {
        activeID = config.id
        persist()
    }

    /// Renames a config (user label). Empty names are ignored so a server isn't left
    /// without a label.
    func rename(_ config: ServerConfig, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = configs.firstIndex(where: { $0.id == config.id }) else { return }
        configs[idx].name = trimmed
        persist()
    }

    // MARK: - Persistence

    private static let fileURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AmneziaLVPN", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("configs.json")
    }()

    private struct Snapshot: Codable {
        var configs: [ServerConfig]
        var activeID: UUID?
    }

    private func persist() {
        let snapshot = Snapshot(configs: configs, activeID: activeID)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }

        // Migration: configs imported before `tunnelConf` existed (especially vpn://
        // links) store raw without the expanded wg-quick text → they weren't considered
        // tunnelable. Re-derive tunnelConf by re-parsing raw so they bring up a real
        // tunnel.
        var migrated = false
        configs = snapshot.configs.map { cfg in
            guard cfg.tunnelConf == nil,
                  let derived = try? ConfigParser.parse(cfg.raw),
                  let tc = derived.tunnelConf
            else { return cfg }
            var c = cfg
            c.tunnelConf = tc
            migrated = true
            return c
        }
        activeID = snapshot.activeID
        if migrated { persist() }
    }
}
