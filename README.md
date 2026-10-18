# Wakelock

A macOS menu bar app (SwiftUI `MenuBarExtra`, macOS 14+, Apple Silicon) that keeps your Mac awake — including with the lid closed — and lets scripts hold expiring leases over a Unix socket.

## Install

Requires the Xcode Command Line Tools (Swift 5.9+).

```sh
scripts/install.sh          # builds, installs /Applications/Wakelock.app + CLI helpers, launches it
```

Then click **Set Up…** in the menu (or run `scripts/setup-sudoers.sh`). That's one macOS admin prompt — Touch ID or password — which installs the sudoers rule for lid-closed mode and a boot-time reset daemon ([`Support/root-setup.sh`](Support/root-setup.sh)). After that, Wakelock never asks again.

Remove everything (app, login item, sudoers rule, boot daemon, support files, prefs) with `scripts/uninstall.sh`.

## How it stays awake

| Mechanism | Covers | Notes |
|---|---|---|
| IOKit `PreventUserIdleSystemSleep` assertion | lid open | Released by the kernel if the app dies. |
| `sudo -n /usr/bin/pmset -a disablesleep 1` | lid closed | Engaged whenever Wakelock is active and *Stay awake with lid closed* is on — it must be set **before** the lid closes, because the Mac sleeps the instant it does. |

The sudoers rule (`/etc/sudoers.d/wakelock`) grants your user exactly those two `pmset` commands and nothing else; it's validated with `visudo -c` before and after install.

Every 5 s the app reads back `pmset -g`, corrects any drift, and shows the **observed** state in the menu. If Wakelock wants the Mac awake but it isn't actually protected (e.g. the sudoers rule is missing, so closing the lid would still sleep it), the menu bar icon becomes a warning triangle and the status says so.

## Safety

`disablesleep` outlives the process, so it is reset to `0` on:

- **launch** (unconditionally), **quit**, logout, and `SIGTERM`/`SIGINT`/`SIGHUP`;
- **crashes** — fatal signals and uncaught exceptions spawn the reset before the process dies;
- **`SIGKILL` / Force Quit** — a detached watchdog (`sh` loop) notices the app is gone and resets;
- **kernel panic / power loss** — a LaunchDaemon installed during setup resets at boot.

Every `sudo`/`pmset` call is killed after 10 s, so a hung call can't hold up a safety reset.

Wakelock also turns itself off when:

- the timer runs out (15 m / 1 h / 2 h / ∞);
- battery drops below the floor (default 20 %) **while on battery power**;
- Low Power Mode is on;
- `ProcessInfo.thermalState` is `.serious` or `.critical`.

A manual session that's turned off this way stays off. Socket leases are kept but ignored while the condition lasts. If the lid is closed (and no external display is attached) when Wakelock turns off, it runs `pmset sleepnow`, because releasing `disablesleep` with the lid already shut doesn't make the Mac sleep by itself.

> Wakelock owns `disablesleep`: if you set it by hand while the app is running, the app will reset it to match its own state.

## Leases (scripts)

Socket: `~/Library/Application Support/Wakelock/sock` (directory `0700`, socket `0600`, same-uid peers only). One command per connection, one reply line.

```
acquire <id> <ttl-seconds>   take or renew a lease (ttl 1–86400)
release <id>
status                       e.g. active=1 manual=0 leases=1 assertion=1 sleepdisabled=1 lid=open blocked=-
list                         <id> <seconds-left> per lease
```

The Mac stays awake while any lease is live. A lease that isn't renewed before its TTL runs out expires. Live leases are listed in the menu, where each can be released.

```sh
WL="$HOME/Library/Application Support/Wakelock/bin/wakelockctl"
"$WL" acquire nightly-backup 600 && ./backup.sh; "$WL" release nightly-backup
```

## Claude Code hooks

Merge [`hooks/claude-settings.example.json`](hooks/claude-settings.example.json) into `~/.claude/settings.json`:

- `UserPromptSubmit` → acquire `claude-<session_id>`
- `PreToolUse` / `PostToolUse` → renew it around every tool call
- `Stop` / `SessionEnd` → release immediately, so the Mac can sleep as soon as Claude finishes

The default TTL is 900 s (`WAKELOCK_CLAUDE_TTL`). It only matters when `Stop` never fires (e.g. you interrupt Claude): that's how long the Mac stays awake afterwards. It also has to outlast your longest single tool call, so raise it if you run builds longer than 15 minutes. You can drop a stuck lease from the menu. The hook never writes to stdout, always exits 0, and does nothing if the payload has no `session_id`.

## Development

```sh
swift build
swift run WakelockCoreTests   # pure-logic checks (CLT ships without XCTest)
scripts/build.sh              # → build/Wakelock.app (ad-hoc signed)
```

`Sources/WakelockCore` holds the pure logic (leases, protocol parsing, pmset parsing, safety policy). `Sources/Wakelock` holds the app (IOKit, pmset, socket, crash guard, UI).
