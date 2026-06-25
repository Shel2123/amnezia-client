import Foundation
import Observation
import AppKit
import Network

/// Real AmneziaWG/WireGuard tunnel driver (no NetworkExtension).
///
/// Brings the tunnel up with the bundled `macos-native-slice/awg-engine` kit
/// (`amneziawg-go` + `awg-quick`). Root is obtained with a single system prompt via
/// `osascript … with administrator privileges` (macOS caches the authorization for
/// ~5 min, so repeated actions don't re-ask for the password). Status is polled:
/// whether `amneziawg-go` is alive and the default route goes through utun.
///
/// Swift here only orchestrates the existing engine; it does not implement VPN logic.
@MainActor
@Observable
final class AwgTunnel {
    private(set) var state: ConnectionState = .disconnected
    private(set) var connectedSince: Date?
    private(set) var errorText: String?

    // Install root — a fully root-owned chain (`/Library` is owned by root:wheel
    // 0755, only root can write), with no spaces in the path.
    nonisolated private static let installRoot = "/Library/AmneziaLVPN"

    // The engine RUNS from this root-owned location, not from the repo or a
    // user-writable bundle: otherwise NOPASSWD sudo would let anyone rewrite the
    // script and gain root. It is copied here from the bundle's Resources on first run.
    nonisolated private static let engineDir = "\(installRoot)/engine"

    // Engine embedded in the app bundle — the SOURCE for the root install. nil if the
    // resource is missing (e.g. in SwiftUI previews).
    nonisolated private static var bundledEngineDir: String? {
        Bundle.main.resourceURL?.appendingPathComponent("awg-engine").path
    }

    // Active config path and interface name (basename without .conf) — static so the
    // synchronous teardown on quit can bring the tunnel down without an instance.
    nonisolated static let confPath = NSTemporaryDirectory() + "amnezia-active.conf"
    nonisolated private static let nameFile = "/var/run/amneziawg/amnezia-active.name"

    private var monitor: Task<Void, Never>?

    // MARK: - Auto-reconnect

    /// Whether the tunnel is auto-restored after a drop / wake from sleep. On by
    /// default: an explicit Disconnect by the user cancels it (we clear
    /// `activeConfig`), so the loop only lives within a session.
    var autoReconnectEnabled = true
    /// Config of the current session — needed to bring the tunnel back up with the
    /// same config after a drop. `nil` means "user disconnected" → no reconnect.
    private var activeConfig: ServerConfig?
    /// Whether this session had at least one successful handshake. Auto-reconnect only
    /// kicks in AFTER a real connection — so an initial connect to a known broken /
    /// unreachable config doesn't spin forever.
    private var hadConnection = false
    /// Pending reconnect attempt (with backoff). Cancelling breaks the loop.
    private var reconnectTask: Task<Void, Never>?
    /// Count of consecutive failed attempts — for exponential backoff. Reset to 0 on a
    /// successful handshake.
    private var reconnectAttempts = 0
    /// Cap on the pause between attempts: 1, 2, 4, 8, 16, 30, 30… seconds.
    private static let maxReconnectDelay: TimeInterval = 30

    // Physical network monitor: react to Wi-Fi↔Ethernet / network changes. `.other`
    // (our utun) is prohibited so bringing the tunnel up isn't itself a network change.
    private let pathMonitor = NWPathMonitor(prohibitedInterfaceTypes: [.other])
    /// Last known state of the physical path — so we react only to a REAL change (not
    /// to every NWPathMonitor update).
    private var lastPathSatisfied = false
    private var lastPrimaryInterface: String?

    init() {
        // System sleep/wake. Blocks are delivered on the main queue, so hopping to
        // MainActor is safe.
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleSleep() }
        }
        // Network change (Wi-Fi↔Ethernet, new Wi-Fi, link back).
        pathMonitor.pathUpdateHandler = { [weak self] path in
            // Snapshot values off-actor, then hop to main.
            let satisfied = path.status == .satisfied
            let primary = path.availableInterfaces.first {
                [.wifi, .wiredEthernet, .cellular].contains($0.type)
            }?.name
            Task { @MainActor in self?.handleNetworkChange(satisfied: satisfied, primary: primary) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "amnezia.lvpn.path"))
    }

    func toggle(config: ServerConfig) {
        switch state {
        case .connected, .connecting, .reconnecting: disconnect()
        default:                                     connect(config: config)
        }
    }

    func connect(config: ServerConfig) {
        // Start of a new session: reset auto-reconnect and remember the config.
        cancelReconnect()
        reconnectAttempts = 0
        hadConnection = false
        activeConfig = config
        startTunnel(config: config)
    }

    /// Brings the tunnel up from `config`. Used both for the initial connect and for
    /// auto-reconnect (`reconnecting = true` keeps the `.reconnecting` phase so the UI
    /// doesn't flash "Connecting…" and the cancel button stays active).
    private func startTunnel(config: ServerConfig, reconnecting: Bool = false) {
        guard let wgQuick = WireGuardConfigBuilder.wgQuick(from: config) else {
            errorText = "Config is not WireGuard/AmneziaWG, cannot start the tunnel."
            state = .disconnected
            return
        }
        if !reconnecting { errorText = nil }
        state = reconnecting ? .reconnecting : .connecting

        // Write the active config to a temporary .conf with 0600 perms. This is the
        // expanded wg-quick text (for a vpn:// link — extracted from it), NOT the raw link.
        do {
            try wgQuick.write(toFile: Self.confPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.confPath)
        } catch {
            errorText = "Could not write config: \(error.localizedDescription)"
            state = .disconnected
            return
        }

        Task.detached {
            let res = Self.runEngine("\(Self.engineDir)/connect.sh", Self.confPath)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if res.code != 0 {
                    self.errorText = Self.adminError(res)
                    self.handleStartFailure()
                } else {
                    self.startMonitoring()
                }
            }
        }
    }

    func disconnect() {
        // Explicit disconnect by the user kills auto-reconnect: forget the session,
        // cancel the pending attempt.
        cancelReconnect()
        activeConfig = nil
        hadConnection = false
        reconnectAttempts = 0
        state = .disconnecting
        // Stop polling immediately, before disconnect.sh runs: otherwise an in-flight
        // iteration could write .connected over our transition down.
        stopMonitoring()
        Task.detached {
            let res = Self.runEngine("\(Self.engineDir)/disconnect.sh", Self.confPath)
            // Check the fact: is the interface actually down (no .name)?
            let stillUp = Self.interfaceUp()
            await MainActor.run { [weak self] in
                guard let self else { return }
                if stillUp {
                    // disconnect.sh didn't work, the tunnel is alive — don't claim it's off.
                    self.errorText = res.code != 0
                        ? Self.adminError(res)
                        : "Could not stop the tunnel."
                    self.state = .connected   // truth: the tunnel is still up
                    self.startMonitoring()    // go back to the real status
                } else {
                    self.connectedSince = nil
                    self.state = .disconnected
                }
            }
        }
    }

    /// Synchronously brings our tunnel down — called on app termination so the
    /// `amneziawg-go` daemon doesn't linger as a root zombie after closing/quitting.
    /// Independent of UI state (which may drift): decides by the presence of our
    /// interface's `.name` file. `disconnect.sh` via `sudo -n` doesn't ask for a
    /// password (sudoers) and removes `.name` → the daemon exits on its own.
    nonisolated static func teardownSync() {
        // No tunnel — nothing to clean up, don't fire an extra sudo.
        guard FileManager.default.fileExists(atPath: nameFile) else { return }
        _ = run("/usr/bin/sudo", ["-n", "\(engineDir)/disconnect.sh", confPath])
    }

    // MARK: - Status polling

    /// How long we wait for the first handshake in the .connecting phase before
    /// declaring the connection failed (server unreachable / wrong keys / port closed).
    private static let handshakeTimeout: TimeInterval = 20

    // Poll intervals. Connecting — frequently (fast detection of the first handshake →
    // connect feels "instant"). Connected — less often: the interface is alive, the
    // handshake rekeys ~120s (threshold 180s), so firing sudo every 2s is wasteful.
    private static let connectingPollInterval: TimeInterval = 0.5
    private static let connectedPollInterval: TimeInterval = 3
    // How often, in the connected phase, to run the EXPENSIVE handshake poll
    // (sudo+status.sh). The cheap interface check runs every tick; this runs ~every 18s.
    private static let handshakeRecheckInterval: TimeInterval = 18

    /// Phases in which the monitor may write transitions (transitions DOWN belong to
    /// disconnect()). Re-checked after every await: while polling ran, the user may
    /// have hit Disconnect — otherwise a "stale" iteration would stick on top.
    private var isMonitoredState: Bool {
        state == .connecting || state == .connected || state == .reconnecting
    }

    private func startMonitoring() {
        monitor?.cancel()
        // Deadline for the first handshake — set when we actually bring the tunnel up
        // (both initial connect and auto-reconnect attempt).
        let connectDeadline = (state == .connecting || state == .reconnecting)
            ? Date().addingTimeInterval(Self.handshakeTimeout) : nil
        monitor = Task { [weak self] in
            var lastHandshakeCheck = Date.distantPast
            while !Task.isCancelled {
                // (1) Cheap interface check (file-exists, NO sudo) — every tick. Catches
                //     a daemon crash / utun disappearance almost for free.
                let up = await Task.detached { Self.interfaceUp() }.value
                guard !Task.isCancelled, let self, self.isMonitoredState else { return }
                if !up { self.handleDrop(); return }

                // The connecting phase needs frequent handshake polling (catch the first
                // handshake fast); connected — conversely, save sudo.
                let connecting = (self.state == .connecting || self.state == .reconnecting)

                // (2) Expensive handshake poll (sudo+status.sh): while connecting — every
                //     tick, while connected — no more often than handshakeRecheckInterval.
                if connecting || Date().timeIntervalSince(lastHandshakeCheck) >= Self.handshakeRecheckInterval {
                    lastHandshakeCheck = Date()
                    let age = await Task.detached { Self.handshakeAgeSeconds() }.value
                    guard !Task.isCancelled, self.isMonitoredState else { return }

                    switch Self.handshakeHealth(age: age) {
                    case .connected:
                        if self.connectedSince == nil { self.connectedSince = Date() }
                        // Success: drop "reconnecting…" and reset backoff.
                        self.hadConnection = true
                        self.reconnectAttempts = 0
                        self.errorText = nil
                        self.state = .connected

                    case .handshaking:
                        if self.state == .connected {
                            // Was connected and the handshake went stale → drop → auto-reconnect.
                            self.handleDrop()
                            return
                        }
                        // Still bringing the tunnel up: wait for the first handshake, but
                        // not forever — otherwise a broken/unreachable server would hang
                        // on "Connecting…" indefinitely.
                        if let deadline = connectDeadline, Date() >= deadline {
                            self.handleConnectTimeout()
                            return
                        }

                    case .down:
                        // handshakeHealth doesn't return .down (interface already checked),
                        // but treat it as a drop just in case.
                        self.handleDrop()
                        return
                    }
                }

                let interval = connecting ? Self.connectingPollInterval : Self.connectedPollInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// A tunnel that was already working dropped (stale handshake or the interface
    /// vanished). If auto-reconnect is on and the session isn't cancelled — bring it
    /// back up with backoff; otherwise go down honestly.
    private func handleDrop() {
        if autoReconnectEnabled, hadConnection, activeConfig != nil {
            scheduleReconnect()
        } else {
            connectedSince = nil
            state = .disconnected
        }
    }

    /// The first handshake didn't arrive within the timeout. Bring the half-up
    /// interface down. If this is recovery of an already-working session — keep
    /// reconnecting with backoff; if it's an initial connect — an honest error.
    private func handleConnectTimeout() {
        Task.detached { _ = Self.runEngine("\(Self.engineDir)/disconnect.sh", Self.confPath) }
        if autoReconnectEnabled, hadConnection, activeConfig != nil {
            scheduleReconnect()
        } else {
            errorText = "Server did not respond, handshake failed. "
                + "Check the config and server availability."
            connectedSince = nil
            state = .disconnected
        }
    }

    /// Couldn't even start connect.sh (sudo/engine returned an error). On the reconnect
    /// path keep trying, otherwise show the error and go down.
    private func handleStartFailure() {
        if autoReconnectEnabled, hadConnection, activeConfig != nil {
            scheduleReconnect()
        } else {
            connectedSince = nil
            state = .disconnected
        }
    }

    /// Schedules a reconnect with exponential backoff. Before bringing the tunnel back
    /// up it tears down any "half-dead" interface. Any Disconnect or new connect
    /// cancels the pending attempt via `cancelReconnect()`.
    private func scheduleReconnect() {
        guard autoReconnectEnabled, activeConfig != nil else {
            connectedSince = nil
            state = .disconnected
            return
        }
        stopMonitoring()
        reconnectTask?.cancel()
        connectedSince = nil
        let attempt = reconnectAttempts
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(attempt)), Self.maxReconnectDelay)
        state = .reconnecting
        errorText = "Connection lost. Reconnecting..."
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.activeConfig != nil else { return }
            // Bring down any not-fully-torn-down interface from the previous attempt so
            // connect.sh doesn't hit "utun already exists".
            await Task.detached { _ = Self.runEngine("\(Self.engineDir)/disconnect.sh", Self.confPath) }.value
            guard !Task.isCancelled, let cfg = self.activeConfig else { return }
            self.startTunnel(config: cfg, reconnecting: true)
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    // MARK: - Sleep/wake

    /// On wake from sleep the handshake has almost certainly gone stale, and the
    /// network may have changed. Don't wait for the monitor to notice (up to 180s) —
    /// bring it back up immediately if the session is active and the user didn't
    /// disconnect manually.
    private func handleWake() {
        guard autoReconnectEnabled, hadConnection, activeConfig != nil else { return }
        reconnectAttempts = 0          // fresh start: first attempt without backoff growth
        scheduleReconnect()
    }

    /// Physical network change. React only to a REAL change: the link came up
    /// (satisfied after offline) OR the primary interface changed (Wi-Fi↔Ethernet). On
    /// a network change the tunnel utun stays "up", but the handshake over the old path
    /// is dead — bring it back up immediately, without waiting 180s for the stale
    /// timeout. The path state is updated ALWAYS (even without a session) so we later
    /// catch the transition, not the first update.
    private func handleNetworkChange(satisfied: Bool, primary: String?) {
        let cameOnline = satisfied && !lastPathSatisfied
        let switchedIface = satisfied && primary != lastPrimaryInterface
        lastPathSatisfied = satisfied
        lastPrimaryInterface = primary

        guard autoReconnectEnabled, hadConnection, activeConfig != nil else { return }
        // Offline (no physical network) — reconnect is pointless, it'll come up on the
        // next satisfied update. React only to the link coming up / changing.
        guard satisfied, cameOnline || switchedIface else { return }
        reconnectAttempts = 0
        scheduleReconnect()
    }

    /// Before sleep, stop polling and the pending reconnect: processes are frozen, and
    /// on wake we bring the tunnel back up from `handleWake()` anyway. Without this a
    /// "stale" poll could record a false drop at the moment of falling asleep.
    private func handleSleep() {
        guard autoReconnectEnabled else { return }
        if state == .connected || state == .connecting || state == .reconnecting {
            cancelReconnect()
            stopMonitoring()
        }
    }

    private func stopMonitoring() {
        monitor?.cancel()
        monitor = nil
    }

    // MARK: - Shell (nonisolated, runs off the main actor)

    /// Tunnel health by the FACT of working, not by the presence of an interface.
    enum TunnelHealth {
        case connected     // fresh WireGuard handshake → traffic actually flows
        case handshaking   // interface is up, but there is (no longer / not yet) a handshake
        case down          // no interface/daemon
    }

    /// Health by handshake age (the interface is checked separately, by the monitor's
    /// cheap step). We consider the tunnel working ONLY with a fresh handshake:
    /// awg-quick brings up utun and routes immediately, regardless of whether the
    /// server replied, so "process alive + route via utun" = a false "Connected" (a
    /// broken config / unreachable server would look connected). The real signal is the
    /// age of the last handshake from UAPI (`status.sh` via root).
    nonisolated private static func handshakeHealth(age: Int?) -> TunnelHealth {
        switch age {
        case .some(let a) where a >= 0 && a <= 180:
            // Fresh handshake (rekey every ~120s) — traffic actually flows.
            return .connected
        case .some:
            // status.sh was read, but there's no/stale handshake → really not connected.
            return .handshaking
        case .none:
            // Couldn't read the handshake (sudo hasn't authorized status.sh yet — e.g.
            // first launch with an old sudoers). Don't punish a potentially working
            // tunnel with a false failure: degrade to the previous route heuristic.
            // Self-heals after the first connect, which provisions sudoers.
            let route = run("/sbin/route", ["-n", "get", "1.1.1.1"])
            return route.out.contains("interface: utun") ? .connected : .handshaking
        }
    }

    /// Whether OUR interface is up (by our tunnel's `.name` file) — regardless of the
    /// handshake. Needed for teardown/disconnect, where the interface's existence is
    /// what matters.
    nonisolated private static func interfaceUp() -> Bool {
        FileManager.default.fileExists(atPath: nameFile)
    }

    /// Age of the last handshake in seconds. `status.sh` reads the root UAPI socket →
    /// `sudo -n` (the sudoers rule is granted at connect).
    ///   `.some(n)` — status.sh ran: n>=0 age, n<0 no handshake yet;
    ///   `.none`    — couldn't read (sudo not authorized / script didn't run).
    nonisolated private static func handshakeAgeSeconds() -> Int? {
        let res = run("/usr/bin/sudo", ["-n", "\(engineDir)/status.sh", confPath])
        guard res.code == 0 else { return nil }
        return Int(res.out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Privileged execution (password asked once)

    /// Name of the sudoers drop-in file that grants passwordless engine execution.
    nonisolated private static let sudoersPath = "/etc/sudoers.d/amnezia-lvpn"
    /// Version marker of the installed engine (next to the engine in the root location).
    nonisolated private static var versionFile: String { "\(engineDir)/.lvpn-version" }

    /// Runs connect.sh/disconnect.sh as root from the root-owned location.
    ///
    /// The first time (or on an engine update) it installs the engine into
    /// `/Library/AmneziaLVPN` and a passwordless sudoers rule — in ONE system password
    /// prompt. After that — `sudo -n` with no password at all. If the install was
    /// cancelled — we fall back to an osascript prompt for this connection only.
    nonisolated private static func runEngine(_ script: String, _ conf: String) -> (code: Int32, out: String) {
        if ensurePrivilegedSetup() {
            return run("/usr/bin/sudo", ["-n", script, conf])
        }
        return runAdmin("\(script) \(conf)")
    }

    /// Setup is ready: the engine of the RIGHT version is installed in the root
    /// location AND sudoers lets its scripts run passwordlessly.
    nonisolated private static func setupReady() -> Bool {
        guard let marker = bundleMarker() else { return false }  // no bundle — not ready
        let installed = (try? String(contentsOfFile: versionFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard installed == marker else { return false }          // engine version differs
        // -n: no prompt; -l <cmd>: rc 0 only if there's a NOPASSWD rule for cmd.
        return run("/usr/bin/sudo", ["-n", "-l", "\(engineDir)/status.sh"]).code == 0
    }

    /// Version marker of the bundled engine: sizes + mtime of the key files
    /// (shell-safe). Changes when the engine is rebuilt/updated → triggers a reinstall.
    nonisolated private static func bundleMarker() -> String? {
        guard let dir = bundledEngineDir else { return nil }
        let fm = FileManager.default
        var parts: [String] = []
        for f in ["connect.sh", "disconnect.sh", "status.sh", "awg-quick", "amneziawg-go", "bash-runtime/bash"] {
            guard let attrs = try? fm.attributesOfItem(atPath: "\(dir)/\(f)"),
                  let size = attrs[.size] as? Int,
                  let mtime = attrs[.modificationDate] as? Date
            else { return nil }
            parts.append("\(size)-\(Int(mtime.timeIntervalSince1970))")
        }
        return parts.joined(separator: ".")
    }

    /// Ensures (1) the engine is installed root-owned at the right version and (2)
    /// sudoers grants passwordless execution of its scripts. If anything is missing —
    /// installs EVERYTHING in one admin prompt. Returns whether `sudo -n` is now
    /// available.
    nonisolated private static func ensurePrivilegedSetup() -> Bool {
        if setupReady() { return true }
        guard let bundled = bundledEngineDir, let marker = bundleMarker() else { return false }

        let user = NSUserName()
        let connect = "\(engineDir)/connect.sh"
        let disconnect = "\(engineDir)/disconnect.sh"
        let status = "\(engineDir)/status.sh"
        let line = "\(user) ALL=(root) NOPASSWD: \(connect), \(disconnect), \(status)"
        let tmpSudoers = "/tmp/amnezia-lvpn.sudoers"

        // One privileged script: install the engine root-owned + the sudoers rule. The
        // engine runs ONLY from the root-owned copy (the user can't rewrite the script
        // and gain root). `chmod -R go-w` removes write for group/other while keeping
        // exec bits. visudo validates the rule before install (a broken sudoers must not
        // break sudo). Fixed paths (/Library, /tmp, /etc) without spaces go unquoted;
        // the source `bundled` is a path to the .app, which MAY contain a space (e.g.
        // "DESKTOP STUFF"), so it's single-quoted (an AppleScript string in double quotes
        // → '...' reaches sh as-is).
        let install =
            "/bin/mkdir -p \(installRoot) && "
            + "/bin/rm -rf \(engineDir) && "
            + "/bin/cp -R '\(bundled)' \(engineDir) && "
            + "/usr/sbin/chown -R root:wheel \(installRoot) && "
            + "/bin/chmod -R go-w \(installRoot) && "
            + "echo \(marker) > \(versionFile) && "
            + "/bin/mkdir -p /etc/sudoers.d && "
            + "echo '\(line)' > \(tmpSudoers) && "
            + "/usr/sbin/visudo -cf \(tmpSudoers) && "
            + "/bin/mv \(tmpSudoers) \(sudoersPath) && "
            + "/usr/sbin/chown root:wheel \(sudoersPath) && "
            + "/bin/chmod 0440 \(sudoersPath)"

        let res = runAdmin(install)
        return res.code == 0 && setupReady()
    }

    nonisolated private static func runAdmin(_ command: String) -> (code: Int32, out: String) {
        let script = "do shell script \"\(command)\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", script])
    }

    nonisolated private static func adminError(_ res: (code: Int32, out: String)) -> String {
        let out = res.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.contains("-128") || out.lowercased().contains("cancel") {
            return "Cancelled, administrator password required."
        }
        return out.isEmpty ? "Could not start the tunnel (code \(res.code))." : out
    }

    nonisolated private static func run(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
