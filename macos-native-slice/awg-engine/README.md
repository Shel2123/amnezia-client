# awg-engine — real AmneziaWG / WireGuard tunnel

A self-contained kit for bringing up a tunnel **without NetworkExtension and without a
paid account**. The engine is the official `amneziawg-go` (supports AWG 2.0: junk
parameters Jc/Jmin/S1-S4/H1-H4/**I1-I5**).

## Contents

| File | What it is |
|---|---|
| `amneziawg-go` | tunnel engine (Go, arm64, v0.2.18) — creates the utun |
| `wg` / `awg` | amneziawg-tools — configures the interface over UAPI (understands AWG parameters) |
| `awg-quick` | official bring-up script (darwin): utun + address + routes + DNS |
| `connect.sh` / `disconnect.sh` | wrappers (locate bash 4, put the engine on PATH, call awg-quick) |
| `status.sh` | prints the age of the last handshake (the real "traffic flows" signal) |

## Requirement

`awg-quick` needs **bash 4+** (macOS ships 3.2). The kit bundles a self-contained bash
under `bash-runtime/`; homebrew bash is used as a fallback:
```bash
brew install bash
```

## Verifying the tunnel manually

1. Export a server config from the real AmneziaVPN as **AmneziaWG / WireGuard** to a
   file, e.g. `~/awg.conf` (wg-quick format: `[Interface]` with
   `PrivateKey`/`Address`/`DNS` and AWG parameters, `[Peer]` with `Endpoint`).
2. Bring the tunnel up (asks for a password):
   ```bash
   ./connect.sh ~/awg.conf
   ```
3. Check that traffic goes through the VPN:
   ```bash
   curl -s https://api.ipify.org ; echo      # should print the server's IP
   ifconfig | grep -A3 utun                   # a utun appears with the address from the config
   ```
4. Bring it down:
   ```bash
   ./disconnect.sh ~/awg.conf
   ```

## Rebuilding the engine (if needed)

```bash
curl -fsSL -o awg.zip https://github.com/amnezia-vpn/amneziawg-go/archive/refs/tags/v0.2.18.zip
unzip awg.zip && cd amneziawg-go-0.2.18 && GOOS=darwin GOARCH=arm64 go build -o ../amneziawg-go .
# tools:
curl -fsSL -o tools.zip https://github.com/amnezia-vpn/amneziawg-tools/archive/refs/heads/master.zip
unzip tools.zip && cd amneziawg-tools-master/src && make    # builds 'wg'; copy → wg and awg
# awg-quick = src/wg-quick/darwin.bash
```

## How the app uses it

The `AmneziaLVPN` app drives this exact kit from Swift (`AwgTunnel`): on first connect
it installs the engine root-owned into `/Library/AmneziaLVPN` plus a passwordless
sudoers rule (one admin prompt), then calls `connect.sh` / `disconnect.sh` / `status.sh`
via `sudo -n` and reports status back to the UI.
