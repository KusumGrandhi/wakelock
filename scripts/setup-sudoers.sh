#!/bin/bash
# One-time root setup for Wakelock:
#  1. /etc/sudoers.d/wakelock lets the current user run ONLY
#       /usr/bin/pmset -a disablesleep 1
#       /usr/bin/pmset -a disablesleep 0
#     without a password. Nothing else is granted.
#  2. A boot-time LaunchDaemon that runs `pmset -a disablesleep 0`, so a kernel
#     panic or power loss while Wakelock was active can't leave sleep disabled.
set -euo pipefail

DEST=/etc/sudoers.d/wakelock
STAGE=/etc/sudoers.d/wakelock.staging   # names containing '.' are ignored by #includedir
DAEMON=/Library/LaunchDaemons/local.wakelock.boot-reset.plist

die() { echo "error: $*" >&2; exit 1; }
[[ $EUID -ne 0 ]] || die "run this as your normal user (it calls sudo itself)"
USER_NAME="$(id -un)"
[[ "$USER_NAME" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ && "$USER_NAME" != ALL ]] || die "unexpected username '$USER_NAME'"

RULE="# Installed by Wakelock (scripts/setup-sudoers.sh). Remove with scripts/uninstall.sh.
# Grants $USER_NAME exactly these two commands, password-free, and nothing else.
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"

# Written straight into a root-owned file (no user-writable temp file between check and install),
# validated there, then moved into place.
echo "Installing $DEST (sudo will ask for your password)…"
printf '%s\n' "$RULE" | sudo /usr/bin/tee "$STAGE" >/dev/null
sudo /bin/chmod 0440 "$STAGE"
sudo /usr/sbin/chown root:wheel "$STAGE"
if ! sudo /usr/sbin/visudo -c -f "$STAGE"; then
  sudo /bin/rm -f "$STAGE"
  die "rule failed validation"
fi
sudo /bin/mv -f "$STAGE" "$DEST"
if ! sudo /usr/sbin/visudo -c; then
  sudo /bin/rm -f "$DEST"
  die "full sudoers config failed validation; removed $DEST"
fi

echo "Installing $DAEMON…"
sudo /usr/bin/tee "$DAEMON" >/dev/null <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>local.wakelock.boot-reset</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/pmset</string>
		<string>-a</string>
		<string>disablesleep</string>
		<string>0</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
PLIST
sudo /bin/chmod 0644 "$DAEMON"
sudo /usr/sbin/chown root:wheel "$DAEMON"   # launchd loads it at next boot; nothing to do until then

# Prove the rule really is password-free: drop cached credentials, then run it.
# (`sudo -n -l` would also succeed via the admin group's password rule.)
sudo -k
sudo -n /usr/bin/pmset -a disablesleep 0 \
  || die "rule installed but sudo -n still asks for a password; is '#includedir /private/etc/sudoers.d' in /etc/sudoers?"
echo "OK: password-free 'pmset -a disablesleep 0|1' works for $USER_NAME."
