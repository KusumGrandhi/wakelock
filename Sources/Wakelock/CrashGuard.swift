import AppKit

// `pmset disablesleep 1` outlives the process, so every exit path must undo it:
//   - normal quit / logout          -> AppDelegate.applicationWillTerminate
//   - SIGTERM / SIGINT / SIGHUP     -> dispatch signal source -> NSApp.terminate
//   - fatal signals (crash, trap,   -> handler below spawns the reset, then re-raises
//     uncaught exception -> abort)
//   - SIGKILL / anything uncatchable -> Watchdog child process notices we're gone
//   - and on the next launch, WakeController.start() resets unconditionally.

/// argv for `sudo -n /usr/bin/pmset -a disablesleep 0`, allocated up front
/// so the signal handler does no allocation.
private let resetArgv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> = {
    let parts = [PMSet.sudo, "-n", PMSet.pmset, "-a", "disablesleep", "0"]
    let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: parts.count + 1)
    for (i, part) in parts.enumerated() { argv[i] = strdup(part) }
    argv[parts.count] = nil
    return argv
}()

/// posix_spawn isn't on POSIX's async-signal-safe list, but on Darwin it is a
/// thin syscall wrapper and is the best available option at crash time.
private func spawnResetAndWait() {
    var pid: pid_t = 0
    guard posix_spawn(&pid, resetArgv[0], nil, nil, resetArgv, environ) == 0 else { return }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
}

private func fatalSignalHandler(_ sig: Int32) {
    spawnResetAndWait()
    // SA_RESETHAND restored the default action; re-raise so the crash report still happens.
    raise(sig)
}

enum CrashGuard {
    private static var signalSources: [DispatchSourceSignal] = []

    static func install() {
        _ = resetArgv  // force initialisation outside of signal context

        // Alternate stack so a main-thread stack overflow can still run the handler
        // (other threads have none; the watchdog covers that case).
        let stackSize = 256 * 1024
        var altStack = stack_t(ss_sp: malloc(stackSize), ss_size: stackSize, ss_flags: 0)
        sigaltstack(&altStack, nil)

        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP, SIGSYS] {
            var action = sigaction()
            action.__sigaction_u = __sigaction_u(__sa_handler: fatalSignalHandler)
            action.sa_flags = SA_RESETHAND | SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(sig, &action, nil)
        }

        // Polite termination: route through NSApp so applicationWillTerminate runs.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                if let app = NSApp {
                    app.terminate(nil)
                } else {
                    spawnResetAndWait()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

/// A tiny detached `sh` loop that waits for this process to disappear (for any
/// reason, including SIGKILL and Force Quit) and then resets disablesleep.
enum Watchdog {
    static func spawn() {
        let script = """
            while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 2; done
            # A relaunched Wakelock has already reset at startup and may have re-enabled since.
            /usr/bin/pgrep -x Wakelock >/dev/null && exit 0
            exec \(PMSet.sudo) -n \(PMSet.pmset) -a disablesleep 0 >/dev/null 2>&1
            """
        let args = ["/bin/sh", "-c", script, "wakelock-watchdog", String(getpid())]
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // New session: survives the parent's process group being signalled.
        // CLOEXEC_DEFAULT: don't leak our fds (e.g. the listening socket) into the child.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var pid: pid_t = 0
        if posix_spawn(&pid, "/bin/sh", nil, &attr, &cargs, environ) != 0 {
            NSLog("Wakelock: failed to spawn watchdog")
        }
    }
}
