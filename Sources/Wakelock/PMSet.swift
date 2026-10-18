import Foundation
import WakelockCore

/// What `pmset` reports right now — the source of truth shown in the menu.
struct PMSetReadback: Equatable {
    var sleepDisabled: Bool?
}

enum PMSet {
    static let sudo = "/usr/bin/sudo"
    static let pmset = "/usr/bin/pmset"

    /// Runs exactly `sudo -n /usr/bin/pmset -a disablesleep 0|1` — the only two
    /// commands the sudoers rule from scripts/setup-sudoers.sh permits.
    /// Returns nil on success, otherwise an error message.
    @discardableResult
    static func setDisableSleep(_ on: Bool) -> String? {
        let r = run(sudo, ["-n", pmset, "-a", "disablesleep", on ? "1" : "0"])
        if r.status == 0 { return nil }
        let detail = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.contains("password is required") {
            return "sudo needs a password — run scripts/setup-sudoers.sh"
        }
        return "pmset disablesleep \(on ? 1 : 0) failed: \(detail.isEmpty ? "exit \(r.status)" : detail)"
    }

    static func readback() -> PMSetReadback {
        let g = run(pmset, ["-g"])
        return PMSetReadback(sleepDisabled: g.status == 0 ? PMSetParser.sleepDisabled(fromPmsetG: g.stdout) : nil)
    }

    /// Runs a command, killing it after `timeout` so a wedged sudo/pmset can
    /// never hold up the queue that safety resets go through.
    static func run(_ executable: String, _ args: [String], timeout: TimeInterval = 10)
        -> (status: Int32, stdout: String, stderr: String)
    {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak p] in
            if let p, p.isRunning { p.terminate() }
        }
        // Drain before waiting so a large `pmset -g assertions` can't fill the pipe and deadlock.
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    /// Puts the Mac to sleep now. Needs no root.
    static func sleepNow() { _ = run(pmset, ["sleepnow"]) }
}

/// Serialises every pmset call on one queue and reconciles against the
/// *observed* SleepDisabled value, so drift (or a failed write) is corrected.
/// Requests coalesce: at most one runs and one waits, and the waiting one is
/// always the latest, so a burst (e.g. dragging a slider) costs one pmset round.
final class PMSetWorker {
    typealias Completion = @MainActor (PMSetReadback, String?) -> Void
    private typealias Job = (desired: Bool, sleepIfOff: Bool, completion: Completion)

    private let queue = DispatchQueue(label: "wakelock.pmset")
    private let lock = NSLock()
    private var next: Job?               // guarded by lock
    private var lastFailedEnable: Date?  // queue-confined from here down
    private var enableError: String?
    private var disableError: String?
    private var sleepPending = false

    /// Reads state, writes `desired` if pmset disagrees, reads back again.
    /// Re-enabling sleep (desired == false) is retried every time; disabling it is
    /// retried at most once a minute so a missing sudoers rule doesn't spam sudo.
    /// `sleepIfOff`: once disablesleep is confirmed 0, put the Mac to sleep (used when
    /// Wakelock turns off with the lid closed, where the Mac wouldn't sleep on its own).
    func reconcile(desired: Bool, sleepIfOff: Bool = false, completion: @escaping Completion) {
        let alreadyQueued = lock.withLock { () -> Bool in
            // A coalesced request must not lose a pending sleep.
            let sleep = sleepIfOff || (next?.sleepIfOff ?? false)
            defer { next = (desired, sleep && !desired, completion) }
            return next != nil
        }
        guard !alreadyQueued else { return }
        queue.async { self.runNext() }
    }

    private func runNext() {
        guard let job = lock.withLock({ () -> Job? in
            defer { next = nil }
            return next
        }) else { return }

        if job.desired {
            sleepPending = false
        } else if job.sleepIfOff {
            sleepPending = true  // kept until disablesleep is confirmed 0, even if this write fails
        }

        var rb = PMSet.readback()
        if rb.sleepDisabled != job.desired {
            let throttled = job.desired && (lastFailedEnable.map { Date().timeIntervalSince($0) < 60 } ?? false)
            if !throttled {
                let error = PMSet.setDisableSleep(job.desired)
                if job.desired {
                    enableError = error
                    lastFailedEnable = error == nil ? nil : Date()
                } else {
                    disableError = error
                }
                rb = PMSet.readback()
            }
        }
        if rb.sleepDisabled == false { disableError = nil }
        if rb.sleepDisabled == true { enableError = nil }

        // Don't sleep if something (e.g. a fresh lease) already wants the Mac awake again.
        let awakeRequested = lock.withLock { next?.desired == true }
        if sleepPending && rb.sleepDisabled == false && !awakeRequested {
            sleepPending = false
            PMSet.sleepNow()
        }

        // While disabling is wanted and unconfirmed, keep showing why the last attempt failed.
        let error = job.desired ? (rb.sleepDisabled == true ? nil : enableError) : disableError
        DispatchQueue.main.async { MainActor.assumeIsolated { job.completion(rb, error) } }
    }

    /// Synchronous reset used on launch and quit; runs after any queued work.
    @discardableResult
    func resetSync() -> String? {
        queue.sync { PMSet.setDisableSleep(false) }
    }
}
