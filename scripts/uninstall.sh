#!/bin/bash
# Remove Wakelock: app, login item, sudoers rule, boot-reset daemon, support files, preferences.
set -uo pipefail

BUNDLE_ID=local.wakelock.Wakelock
SUPPORT="$HOME/Library/Application Support/Wakelock"
SUDOERS=/etc/sudoers.d/wakelock
DAEMON=/Library/LaunchDaemons/local.wakelock.boot-reset.plist

APPS=()
for candidate in /Applications/Wakelock.app "$HOME/Applications/Wakelock.app"; do
  [ -d "$candidate" ] && APPS+=("$candidate")
done

if pgrep -x Wakelock >/dev/null; then
  echo "Quitting Wakelock…"
  pkill -TERM -x Wakelock
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Wakelock >/dev/null || break; sleep 0.5; done
  pkill -KILL -x Wakelock 2>/dev/null
fi

# Unregister the login item (SMAppService) before the bundle disappears.
for app in "${APPS[@]+"${APPS[@]}"}"; do
  "$app/Contents/MacOS/Wakelock" --unregister-login-item && echo "Unregistered login item ($app)"
done

# Make sure sleep is re-enabled while the sudoers rule still exists.
sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null || sudo /usr/bin/pmset -a disablesleep 0

for app in "${APPS[@]+"${APPS[@]}"}"; do
  rm -rf "$app" && echo "Removed $app"
done
rm -rf "$SUPPORT" && echo "Removed $SUPPORT"
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 && echo "Removed preferences"

if [ -e "$DAEMON" ]; then
  sudo /bin/launchctl bootout system "$DAEMON" 2>/dev/null
  sudo rm -f "$DAEMON" && echo "Removed $DAEMON"
fi
if [ -e "$SUDOERS" ]; then
  sudo rm -f "$SUDOERS" && echo "Removed $SUDOERS"
  sudo /usr/sbin/visudo -c >/dev/null || echo "warning: visudo -c reports a problem in your sudoers config" >&2
fi

echo
pmset -g | grep -i SleepDisabled || true

for settings in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json"; do
  if [ -f "$settings" ] && grep -q wakelock-claude-hook "$settings"; then
    echo "note: $settings still references wakelock-claude-hook; remove those hook entries by hand." >&2
  fi
done
echo "Wakelock uninstalled."
