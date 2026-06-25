#!/bin/bash
# Brings up an AmneziaWG / WireGuard tunnel from a .conf via amneziawg-go + awg-quick.
# Usage:  ./connect.sh /path/to/config.conf
# Will ask for a password (awg-quick re-invokes itself via sudo).
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$1"
[ -n "$CONF" ] || { echo "Usage: $0 /path/to/config.conf"; exit 1; }
[ -f "$CONF" ] || { echo "Config not found: $CONF"; exit 1; }

# --- Privilege-escalation guard ---
# This script is installed root-owned and not user-writable, BUT the input .conf lives
# in user-writable tmp. A wg-quick config may carry PostUp/PreUp/PostDown/PreDown hooks
# — awg-quick would run them as root (sudo -n grants passwordless execution). Strip
# those hooks into a root-only copy and work only with it. The filename is preserved so
# the interface name (basename without .conf) doesn't change.
SAN_DIR=/Library/AmneziaLVPN/run
mkdir -p "$SAN_DIR" && chmod 0700 "$SAN_DIR"
SAN="$SAN_DIR/$(basename "$CONF")"
grep -viE '^[[:space:]]*(PostUp|PreUp|PostDown|PreDown)[[:space:]]*=' "$CONF" > "$SAN" || true
chmod 0600 "$SAN"
CONF="$SAN"

# awg-quick needs bash 4+. macOS ships 3.2 → use the bundled bash from bash-runtime
# (self-contained, with @loader_path dylibs); fall back to homebrew if present.
BASH4=""
for b in "$DIR/bash-runtime/bash" /opt/homebrew/bin/bash /usr/local/bin/bash; do
  if [ -x "$b" ] && "$b" -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' 2>/dev/null; then BASH4="$b"; break; fi
done
[ -n "$BASH4" ] || { echo "bash 4+ required. Install: brew install bash"; exit 1; }

# Keep engine/tools alongside — awg-quick adds its own folder to PATH and finds them.
export PATH="$DIR:$PATH"

# Idempotency: an interrupted previous run may have left an orphaned daemon and
# .name/.sock for this same interface → a new `up` would fail with "already exists".
# awg-quick derives the interface name from the config filename without .conf.
IFACE="$(basename "$CONF" .conf)"
NAMEFILE="/var/run/amneziawg/$IFACE.name"
if [ -f "$NAMEFILE" ]; then
  echo "→ Cleaning orphaned state from a previous run ($IFACE)"
  REAL="$(cat "$NAMEFILE" 2>/dev/null || true)"
  [ -n "$REAL" ] && rm -f "/var/run/amneziawg/$REAL.sock" 2>/dev/null || true
  rm -f "$NAMEFILE" 2>/dev/null || true
  # The daemon watches .name and exits on its own; give it a moment.
  sleep 1
fi

echo "→ Bringing up the tunnel from $CONF (engine: $DIR/amneziawg-go)"
exec "$BASH4" "$DIR/awg-quick" up "$CONF"
