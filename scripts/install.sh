#!/bin/bash
# Build and install Wakelock.app to /Applications plus the CLI helpers.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DEST="/Applications/Wakelock.app"
BIN_DIR="$HOME/Library/Application Support/Wakelock/bin"

"$ROOT/scripts/build.sh"

if pgrep -x Wakelock >/dev/null; then
  echo "Quitting running Wakelock…"
  pkill -TERM -x Wakelock || true   # SIGTERM -> app resets disablesleep on the way out
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Wakelock >/dev/null || break; sleep 0.5; done
fi

rm -rf "$APP_DEST"
ditto "$ROOT/build/Wakelock.app" "$APP_DEST"
echo "Installed $APP_DEST"

mkdir -p "$BIN_DIR"
chmod 700 "$HOME/Library/Application Support/Wakelock"
install -m 0755 "$ROOT/bin/wakelockctl" "$BIN_DIR/wakelockctl"
install -m 0755 "$ROOT/hooks/wakelock-claude-hook" "$BIN_DIR/wakelock-claude-hook"
echo "Installed CLI helpers to $BIN_DIR"

if [ ! -e /etc/sudoers.d/wakelock ]; then
  echo
  echo "Next: click \"Set Up…\" in the Wakelock menu (or run scripts/setup-sudoers.sh) to enable lid-closed mode."
fi

open "$APP_DEST"
