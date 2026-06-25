# AmneziaLVPN — native SwiftUI AmneziaWG / WireGuard client for macOS

A small, native macOS VPN client built with SwiftUI. It imports AmneziaVPN configs
(`vpn://` links, WireGuard `.conf`, or Amnezia JSON) and brings up a real
**AmneziaWG / WireGuard** tunnel — **without NetworkExtension and without a paid Apple
Developer account**.

The tunnel is driven by the bundled `awg-engine` kit (the official `amneziawg-go` +
`awg-quick`). Swift only orchestrates the engine; it does not implement VPN logic.

## Structure

```
macos-native-slice/
├── AmneziaLVPN/                 # SwiftUI app (Xcode project)
│   └── AmneziaLVPN/
│       ├── AmneziaNativeSliceApp.swift  # @main, window + menu bar extra, shared state
│       ├── RootView.swift               # tabs: Connection / Servers
│       ├── ContentView.swift            # Home: status orb, server card, Connect button
│       ├── ConfigsView.swift            # server list, import, rename, delete
│       ├── MenuBarContent.swift         # menu bar dropdown
│       ├── AwgTunnel.swift              # real tunnel driver (orchestrates awg-engine)
│       ├── ConfigStore.swift            # config list + active + persistence
│       ├── ConfigParser.swift           # vpn:// / .conf / JSON → ServerConfig
│       ├── WireGuardConfigBuilder.swift # ServerConfig → wg-quick text
│       ├── ConnectionState.swift        # UI-level connection state
│       ├── Pinger.swift                 # TCP-probe latency to the endpoint
│       ├── ServerConfig.swift           # saved config model
│       └── ServerInfo.swift             # display model for the Home card
└── awg-engine/                  # self-contained tunnel kit (see awg-engine/README.md)
    ├── amneziawg-go             # tunnel engine (Go, arm64) — creates the utun
    ├── wg / awg                 # amneziawg-tools — UAPI config
    ├── awg-quick                # official bring-up script (utun + routes + DNS)
    ├── bash-runtime/            # bundled bash 4+ (macOS ships 3.2)
    └── connect.sh / disconnect.sh / status.sh
```

## How it works

- **Import** a config on the *Servers* tab. The parser expands `vpn://` links and
  Amnezia JSON into ready wg-quick text (extracting the nested WireGuard/AmneziaWG
  container and substituting DNS placeholders); imported `.conf` files are used as-is.
- **Connect** on the *Connection* tab (or from the menu bar). `AwgTunnel` writes the
  active config to a 0600 temp file and calls the engine.
- **Privileged setup runs once.** On first connect the app installs the engine
  root-owned into `/Library/AmneziaLVPN` plus a passwordless `sudoers` drop-in (one
  admin prompt). After that the engine runs via `sudo -n` with no password. The engine
  executes only from the root-owned copy, and the wrappers strip `PostUp`/`PreUp`/
  `PostDown`/`PreDown` hooks so a user-writable config can't escalate to root.
- **Status is polled** from the real handshake age (`status.sh` via UAPI), not just the
  presence of the interface — so a broken config / unreachable server doesn't show a
  false "Connected".
- **Auto-reconnect** with exponential backoff handles drops, sleep/wake, and network
  changes (Wi-Fi↔Ethernet). An explicit Disconnect cancels it.

## Requirements

- macOS (Apple Silicon, arm64) — the bundled engine binaries are arm64.
- Xcode (Swift 6, SwiftUI).
- `awg-quick` needs bash 4+. A self-contained bash is bundled under
  `awg-engine/bash-runtime/`; homebrew bash is used as a fallback.

## Build & run

1. Open `AmneziaLVPN/AmneziaLVPN.xcodeproj` in Xcode.
2. Make sure `awg-engine/` is included in the app target's **Copy Bundle Resources**
   (it ships in `…/AmneziaLVPN.app/Contents/Resources/awg-engine`).
3. Build & run (⌘R). On first connect macOS will prompt for an administrator password
   to install the engine and the sudoers rule.

## Importing a config

Export a server from the real AmneziaVPN app as **AmneziaWG / WireGuard**, then on the
*Servers* tab paste the `vpn://` link / `.conf` / JSON, or import from a file.
OpenVPN/XRay/Shadowsocks configs are recognized but not tunneled by this client.

## Security notes

- Never commit real configs — they contain private keys and live endpoints. `*.conf`
  and `*.vpn` are git-ignored.
- The engine and its sudoers rule are installed root-owned and validated with `visudo`;
  the engine only ever runs from `/Library/AmneziaLVPN`, never from a user-writable path.

See `awg-engine/README.md` for engine internals and how to rebuild the binaries.

## License

GPL-3.0, inherited from the AmneziaVPN project. See [LICENSE](LICENSE). The bundled
`amneziawg-go` and `amneziawg-tools` (`wg`/`awg`/`awg-quick`) are separate projects by
the AmneziaVPN authors, distributed under their own licenses.
