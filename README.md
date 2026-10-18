# Wakelock

**Keep your Mac awake — even with the lid closed — and let Claude Code keep it awake only while it's actually working.**

Wakelock is a small native menu bar app for Apple Silicon Macs (macOS 14+), written in Swift/SwiftUI. Turn it on by hand for a fixed time or indefinitely, or let scripts and Claude Code hold short-lived *leases* over a local socket: the Mac stays awake while any lease is live and is free to sleep the moment the work finishes.

It's built safety-first: sleep is always restored when Wakelock quits, crashes or is killed, and it switches itself off on low battery, Low Power Mode or high temperature.

---

## Features

- **Lid-closed mode** — stays awake with the lid shut, on battery, no external display needed.
- **Manual sessions** — one switch, with 15 m / 1 h / 2 h / ∞ durations.
- **Claude Code integration** — hooks keep the Mac awake while Claude is working on a prompt and release the moment it's done.
- **Script leases** — `wakelockctl acquire build 600` from any script; leases expire if not renewed.
- **Truthful UI** — the menu shows what `pmset` actually reports, not what the app hopes; a warning icon appears if the Mac isn't really protected.
- **Safety auto-off** — battery floor (default 20 %, adjustable), Low Power Mode, thermal pressure.
- **Launch at login**, one-time setup with a single admin prompt, and a clean uninstaller.

## Install

Requires Xcode or the Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/KusumGrandhi/wakelock.git
cd wakelock
scripts/install.sh
```

This builds the app, installs it to `/Applications/Wakelock.app`, installs the `wakelockctl` CLI and the Claude hook into `~/Library/Application Support/Wakelock/bin/`, and launches it. Look for the ☕ in the menu bar.

**Enable lid-closed mode (once):** open the menu and click **Set Up…**. macOS asks for your admin password one time; Wakelock never asks again. (Terminal alternative: `scripts/setup-sudoers.sh`.)

## Using it

| Control | What it does |
|---|---|
| **Manual** switch | Keep awake for the selected duration. |
| **Duration** | 15 m, 1 h, 2 h or ∞ for manual sessions. |
| **Battery floor** | Turns off below this charge while unplugged. |
| **Stay awake with lid closed** | Also keep awake with the lid shut (needs the one-time setup). |
| **Launch at login** | Start Wakelock when you log in. |
| **Script leases** | Live leases with time left; ✕ releases one. |
| **Actual system state** | Live readback from `pmset`. An orange mark means reality differs from what Wakelock wants. |

Menu bar icon: ☕ outline = off, ☕ filled = keeping awake, ⚠️ = wants to keep awake but can't (e.g. setup not done).

## Claude Code integration

Merge [`hooks/claude-settings.example.json`](hooks/claude-settings.example.json) into the `hooks` section of `~/.claude/settings.json` (keep any hooks you already have — each event takes a list):

| Hook | Action |
|---|---|
| `UserPromptSubmit` | acquire a lease `claude-<session_id>` |
| `PreToolUse`, `PostToolUse` | renew it around every tool call |
| `Stop`, `SessionEnd` | release it immediately |

So the Mac stays awake — lid closed included — exactly while Claude is working on a prompt, and can sleep the moment Claude finishes. If a session is interrupted and `Stop` never fires, the lease expires on its own after 15 minutes (`WAKELOCK_CLAUDE_TTL`, in seconds). Raise it if single tool calls (e.g. long builds) run longer than that.

> A turn counts as finished when Claude's reply ends — even if a background task it started is still running. Work you want covered should happen inside the turn.

The hook never writes to stdout (so it can't inject text into the prompt), always exits 0, and does nothing if Wakelock isn't running.

## Script leases

```sh
WL="$HOME/Library/Application Support/Wakelock/bin/wakelockctl"

"$WL" acquire nightly-backup 600     # take or renew a 10-minute lease
./backup.sh
"$WL" release nightly-backup

"$WL" status    # active=1 manual=0 leases=1 assertion=1 sleepdisabled=1 lid=closed blocked=-
"$WL" list      # <id> <seconds-left> per lease
```

For long jobs, re-run `acquire` with the same id periodically — that renews it.

**Protocol** — Unix socket at `~/Library/Application Support/Wakelock/sock`, one command per connection, one reply line:

```
acquire <id> <ttl-seconds>   id: 1–128 chars of [A-Za-z0-9._:@-]; ttl: 1–86400
release <id>
status
list
```

Replies start with `ok` or `err`. The socket directory is `0700`, the socket `0600`, and connections from other users are rejected.

## How it works

| Mechanism | Covers | Notes |
|---|---|---|
| IOKit `PreventUserIdleSystemSleep` assertion | lid open | Dropped automatically by the kernel if the app dies. |
| `sudo -n /usr/bin/pmset -a disablesleep 1` | lid closed | The only thing that survives closing the lid. Engaged whenever Wakelock is active, because it must be in place *before* the lid closes. |

The one-time setup ([`Support/root-setup.sh`](Support/root-setup.sh)) installs `/etc/sudoers.d/wakelock`, which lets your user run **exactly** `pmset -a disablesleep 1` and `pmset -a disablesleep 0` without a password — nothing else. It's validated with `visudo -c` before being moved into place.

Every 5 seconds Wakelock reads back `pmset -g`, corrects any drift, and shows the observed state.

## Safety

`disablesleep` outlives the process, so Wakelock resets it to `0` on every exit path it can reach:

| Event | Handled by |
|---|---|
| Launch | Unconditional reset on startup |
| Quit, logout, `SIGTERM` / `SIGINT` / `SIGHUP` | Normal shutdown path |
| Crash (fatal signal, uncaught exception) | Signal handler spawns the reset before dying |
| `SIGKILL`, Force Quit | Detached watchdog notices the app is gone |
| Kernel panic, power loss | LaunchDaemon resets at boot |

Every `sudo`/`pmset` call is killed after 10 s, so a hung call can't hold up a reset.

Wakelock also turns itself **off** when:

- the manual timer runs out;
- battery drops below the floor **while unplugged**;
- Low Power Mode is on;
- `ProcessInfo.thermalState` reaches `.serious` or `.critical`.

A manual session that's turned off this way stays off. Leases are kept but ignored until the condition clears. If the lid is already closed (and no display is attached) when Wakelock turns off, it runs `pmset sleepnow` — releasing `disablesleep` alone wouldn't put a closed Mac to sleep.

> Wakelock owns `disablesleep`: if you change it by hand while Wakelock is running, it will be set back to match Wakelock's state.

## Uninstall

```sh
scripts/uninstall.sh
```

Quits the app, unregisters the login item, re-enables sleep, and removes the app, the sudoers rule, the boot daemon, support files and preferences. It reminds you to remove the hook entries from your Claude settings if they're present.

## Development

```sh
swift build
swift run WakelockCoreTests     # pure-logic tests (Command Line Tools ship without XCTest)
scripts/build.sh                # → build/Wakelock.app (ad-hoc signed)
```

```
Sources/WakelockCore/   pure logic: leases, socket protocol, pmset parsing, safety policy, manual session
Sources/Wakelock/       the app: IOKit assertion, pmset worker, socket server, crash guard, SwiftUI menu
Support/                Info.plist and the root setup script bundled into the app
scripts/                build, install, setup, uninstall
bin/wakelockctl         lease CLI
hooks/                  Claude Code hook and example settings
```
