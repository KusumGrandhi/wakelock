#!/bin/bash
# Wakelock one-time root setup. Runs AS ROOT, invoked through the macOS admin
# prompt (Touch ID or password) by the app's "Set Up…" button or by
# scripts/setup-sudoers.sh. Usage: root-setup.sh <username>
#  1. /etc/sudoers.d/wakelock lets <username> run ONLY
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
[[ $EUID -eq 0 ]] || die "must run as root"
USER_NAME="${1:-}"
[[ "$USER_NAME" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ && "$USER_NAME" != ALL && "$USER_NAME" != root ]] \
  || die "unexpected username '$USER_NAME'"
/usr/bin/id "$USER_NAME" >/dev/null 2>&1 || die "no such user '$USER_NAME'"

# Root-owned staging file: nothing user-writable between validation and install.
umask 077
cat >"$STAGE" <<RULE
# Installed by Wakelock. Remove with scripts/uninstall.sh.
# Grants $USER_NAME exactly these two commands, password-free, and nothing else.
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
RULE
/bin/chmod 0440 "$STAGE"
/usr/sbin/chown root:wheel "$STAGE"
if ! /usr/sbin/visudo -c -f "$STAGE"; then
  /bin/rm -f "$STAGE"
  die "rule failed validation"
fi
/bin/mv -f "$STAGE" "$DEST"
if ! /usr/sbin/visudo -c; then
  /bin/rm -f "$DEST"
  die "full sudoers config failed validation; removed $DEST"
fi

# launchd loads it at next boot; nothing to run until then.
cat >"$DAEMON" <<'PLIST'
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
/bin/chmod 0644 "$DAEMON"
/usr/sbin/chown root:wheel "$DAEMON"
echo "Installed $DEST and $DAEMON"
