#!/bin/bash
# One-time setup for lid-closed mode, from the terminal. Same as the app's
# "Set Up…" button: one macOS admin prompt (Touch ID or password), then never again.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
die() { echo "error: $*" >&2; exit 1; }
[[ $EUID -ne 0 ]] || die "run this as your normal user"

/usr/bin/osascript \
  -e 'on run argv' \
  -e 'do shell script "/bin/bash " & quoted form of (item 1 of argv) & " " & quoted form of (item 2 of argv) with prompt "Wakelock needs one-time permission to keep your Mac awake with the lid closed." with administrator privileges' \
  -e 'end run' \
  "$ROOT/Support/root-setup.sh" "$(id -un)"

# Prove the rule really is password-free (drop cached credentials, then run it).
sudo -k
sudo -n /usr/bin/pmset -a disablesleep 0 \
  || die "rule installed but sudo -n still asks for a password; is '#includedir /private/etc/sudoers.d' in /etc/sudoers?"
echo "OK: password-free 'pmset -a disablesleep 0|1' works for $(id -un)."
