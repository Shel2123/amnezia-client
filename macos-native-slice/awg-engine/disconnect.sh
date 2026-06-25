#!/bin/bash
# Brings the tunnel down. Usage: ./disconnect.sh /path/to/config.conf
# (the same file/name as for connect.sh)
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$1"
[ -n "$CONF" ] || { echo "Usage: $0 /path/to/config.conf"; exit 1; }

# Same sanitization as in connect.sh: awg-quick `down` also runs PostDown/PreDown from
# the config as root. Work with the sanitized root-only copy.
if [ -f "$CONF" ]; then
  SAN_DIR=/Library/AmneziaLVPN/run
  mkdir -p "$SAN_DIR" && chmod 0700 "$SAN_DIR"
  SAN="$SAN_DIR/$(basename "$CONF")"
  grep -viE '^[[:space:]]*(PostUp|PreUp|PostDown|PreDown)[[:space:]]*=' "$CONF" > "$SAN" || true
  chmod 0600 "$SAN"
  CONF="$SAN"
fi

# Bundled bash from bash-runtime (fallback — homebrew). See connect.sh.
BASH4=""
for b in "$DIR/bash-runtime/bash" /opt/homebrew/bin/bash /usr/local/bin/bash; do
  if [ -x "$b" ] && "$b" -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' 2>/dev/null; then BASH4="$b"; break; fi
done
[ -n "$BASH4" ] || { echo "bash 4+ required. Install: brew install bash"; exit 1; }

export PATH="$DIR:$PATH"
exec "$BASH4" "$DIR/awg-quick" down "$CONF"
