#!/bin/bash
# Prints the age (in seconds) of the last WireGuard handshake for the active tunnel.
# This is the ONLY reliable sign that traffic actually flows through the server:
# awg-quick brings up the interface/routes immediately, regardless of whether the
# server replied. Requires root (the UAPI socket is owned by root) → run via sudo.
#
# Usage:  ./status.sh /path/to/config.conf
# Output (a single number on stdout):
#   >= 0  — seconds since the last handshake (0 = just now)
#   -1    — no interface, or no handshake yet/anymore
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$1"
[ -n "$CONF" ] || { echo -1; exit 0; }

# awg-quick derives the interface name from the config filename without .conf; the real
# utun is recorded in /var/run/amneziawg/<iface>.name.
IFACE="$(basename "$CONF" .conf)"
NAMEFILE="/var/run/amneziawg/$IFACE.name"
[ -f "$NAMEFILE" ] || { echo -1; exit 0; }
REAL="$(cat "$NAMEFILE" 2>/dev/null || true)"
[ -n "$REAL" ] || { echo -1; exit 0; }

export PATH="$DIR:$PATH"
# latest-handshakes: lines "<pubkey>\t<unix_ts>"; 0 = no handshake yet.
TS="$("$DIR/awg" show "$REAL" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')"
[ -n "$TS" ] || { echo -1; exit 0; }
case "$TS" in (*[!0-9]*|"") echo -1; exit 0;; esac
[ "$TS" -gt 0 ] || { echo -1; exit 0; }

echo $(( $(date +%s) - TS ))
