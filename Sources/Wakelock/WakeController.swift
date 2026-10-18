import AppKit
import ServiceManagement
import WakelockCore

enum WakeDuration: Int, CaseIterable, Identifiable {
    case fifteenMinutes = 900
    case oneHour = 3600
    case twoHours = 7200
    case indefinite = 0

    var id: Int { rawValue }
    var interval: TimeInterval? { self == .indefinite ? nil : TimeInterval(rawValue) }
    var label: String {
        switch self {
        case .fifteenMinutes: return "15m"
        case .oneHour: return "1h"
        case .twoHours: return "2h"
        case .indefinite: return "∞"
        }
    }
}

/// Owns the desired state (manual session + socket leases), applies safety
/// policy, and drives the two mechanisms:
///   - an IOKit PreventUserIdleSystemSleep assertion (enough while the lid is open)
///   - `pmset disablesleep 1` (the only thing that survives closing the lid).
/// disablesleep has to be set *before* the lid closes — the Mac sleeps on close —
/// so it is engaged whenever Wakelock is active and "lid closed" is enabled.
@MainActor
final class WakeController: ObservableObject {
    private enum Key {
        static let duration = "duration", batteryFloor = "batteryFloor", closedLid = "closedLidEnabled"
    }

    // MARK: Settings

    @Published var duration: WakeDuration {
        didSet {
            defaults.set(duration.rawValue, forKey: Key.duration)
            if session.isOn { session.start(duration: duration.interval, now: Date()) }
        }
    }
    @Published var batteryFloor: Int {
        didSet { defaults.set(batteryFloor, forKey: Key.batteryFloor); tick() }
    }
    @Published var closedLidEnabled: Bool {
        didSet { defaults.set(closedLidEnabled, forKey: Key.closedLid); reconcile() }
    }
    @Published private(set) var launchAtLogin = false

    // MARK: State

    @Published private(set) var session = ManualSession()
    @Published private(set) var leases = LeaseTable()
    @Published private(set) var blockReason: String?
    @Published private(set) var wantAwake = false
    @Published private(set) var readback = PMSetReadback()
    @Published private(set) var pmsetError: String?
    @Published private(set) var loginItemError: String?
    @Published var socketError: String?
    @Published private(set) var sudoersInstalled = PMSet.sudoersInstalled
    @Published private(set) var setupInProgress = false
    @Published private(set) var battery = BatteryInfo(percent: nil, onBatteryPower: false)
    @Published private(set) var lidClosed: Bool?
    @Published private(set) var now = Date()

    var assertionHeld: Bool { assertion.isHeld }
    /// Only Macs with a lid need disablesleep; desktops get by on the assertion.
    var wantDisableSleep: Bool { wantAwake && closedLidEnabled && lidClosed != nil }
    /// Lid-closed mode is wanted on this Mac but the one-time root setup hasn't run.
    var needsSetup: Bool { closedLidEnabled && lidClosed != nil && !sudoersInstalled }

    /// Wanted awake but the system isn't actually protected (e.g. no sudoers rule,
    /// so closing the lid would still sleep the Mac).
    var isDegraded: Bool {
        wantAwake && (!assertion.isHeld || (wantDisableSleep && readback.sleepDisabled != true))
    }

    private let defaults = UserDefaults.standard
    private let assertion = PowerAssertion()
    private let pmWorker = PMSetWorker()
    private var timer: Timer?

    init() {
        defaults.register(defaults: [Key.duration: WakeDuration.oneHour.rawValue, Key.batteryFloor: 20, Key.closedLid: true])
        duration = WakeDuration(rawValue: defaults.integer(forKey: Key.duration)) ?? .oneHour
        batteryFloor = defaults.integer(forKey: Key.batteryFloor)
        closedLidEnabled = defaults.bool(forKey: Key.closedLid)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Lifecycle

    func start() {
        // Safety: never inherit disablesleep=1 from a previous run that died uncleanly.
        pmsetError = pmWorker.resetSync()

        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)  // keep ticking while the menu is open
        timer = t

        // React immediately to the safety signals instead of waiting for the next tick.
        // Observers live as long as the app, so their tokens are never removed.
        let onChange: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        let nc = NotificationCenter.default
        _ = nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main, using: onChange)
        _ = nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: onChange)
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: onChange)

        tick()
    }

    func shutdown() {
        timer?.invalidate()
        assertion.release()
        pmWorker.resetSync()
    }

    // MARK: Control

    func setManual(_ on: Bool) {
        if on {
            guard blockReason == nil else { return }
            session.start(duration: duration.interval, now: Date())
        } else {
            session.stop()
        }
        tick()
    }

    func release(lease id: String) {
        leases.release(id)
        tick()
    }

    /// One admin prompt (Touch ID or password) installs the sudoers rule; never asked again.
    func runSetup() {
        guard !setupInProgress else { return }
        guard let script = Bundle.main.path(forResource: "root-setup", ofType: "sh") else {
            pmsetError = "Setup script missing from the app bundle — reinstall with scripts/install.sh"
            return
        }
        setupInProgress = true
        DispatchQueue.global().async {
            let error = PMSet.runRootSetup(script: script)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.setupInProgress = false
                    self.pmsetError = error
                    self.pmWorker.clearEnableThrottle()
                    self.tick()
                }
            }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        loginItemError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginItemError = "Launch at login: \(error.localizedDescription)"
        }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if status == .requiresApproval {
            loginItemError = "Approve Wakelock in System Settings › General › Login Items"
        }
    }

    /// Re-evaluates timers, leases and safety, then applies the result.
    func tick() {
        now = Date()
        leases.expire(now: now)
        battery = SystemProbe.battery()
        lidClosed = SystemProbe.lidClosed()
        sudoersInstalled = PMSet.sudoersInstalled
        blockReason = SafetyPolicy.blockReason(SafetyInputs(
            batteryPercent: battery.percent,
            onBatteryPower: battery.onBatteryPower,
            batteryFloor: batteryFloor,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState
        ))
        // Leases survive a block (scripts keep renewing them); the manual session doesn't.
        session.update(now: now, blockReason: blockReason)
        reconcile()
    }

    private func reconcile() {
        let wasAwake = wantAwake
        wantAwake = WakePolicy.wantAwake(manualOn: session.isOn, hasLeases: !leases.isEmpty, blockReason: blockReason)
        assertion.set(wantAwake, reason: "Wakelock keeping the Mac awake")
        // Releasing disablesleep with the lid already closed doesn't re-trigger clamshell
        // sleep, so ask for it — unless a display is attached (clamshell mode in use).
        let sleepIfOff = wasAwake && !wantAwake && lidClosed == true && NSScreen.screens.isEmpty
        pmWorker.reconcile(desired: wantDisableSleep, sleepIfOff: sleepIfOff) { [weak self] rb, error in
            self?.readback = rb
            self?.pmsetError = error
        }
    }

    // MARK: Socket protocol

    func handle(line: String) -> String {
        switch CommandParser.parse(line) {
        case .failure(let error):
            return "err \(error)"
        case .success(.acquire(let id, let ttl)):
            guard leases.acquire(id, ttl: ttl, now: Date()) else { return "err too many leases" }
            tick()
            return "ok \(id) ttl=\(Int(ttl))" + (blockReason.map { " blocked=\"\($0)\"" } ?? "")
        case .success(.release(let id)):
            let existed = leases.release(id)
            tick()
            return existed ? "ok" : "ok (no such lease)"
        case .success(.status):
            return statusReply
        case .success(.list):
            let rows = leases.sorted.map { "\($0.id) \(max(0, Int($0.expiry.timeIntervalSinceNow)))" }
            return rows.isEmpty ? "(no leases)" : rows.joined(separator: "\n")
        }
    }

    private var statusReply: String {
        func flag(_ b: Bool?) -> String { b.map { $0 ? "1" : "0" } ?? "?" }
        return [
            "active=\(flag(wantAwake))",
            "manual=\(flag(session.isOn))",
            "leases=\(leases.count)",
            "assertion=\(flag(assertion.isHeld))",
            "sleepdisabled=\(flag(readback.sleepDisabled))",
            "lid=\(lidClosed.map { $0 ? "closed" : "open" } ?? "none")",
            "blocked=\(blockReason.map { "\"\($0)\"" } ?? "-")",
        ].joined(separator: " ")
    }

    // MARK: Presentation

    var statusText: String {
        if let reason = blockReason {
            return leases.isEmpty ? "Off — \(reason)" : "Blocked — \(reason)"
        }
        guard wantAwake else { return "Off" }
        if isDegraded {
            return wantDisableSleep && readback.sleepDisabled != true
                ? "Awake — lid open only"
                : "Not protected — power assertion failed"
        }
        var parts: [String] = []
        if session.isOn {
            parts.append(session.expiry.map { "\(WakePolicy.format($0.timeIntervalSince(now))) left" } ?? "indefinitely")
        }
        if !leases.isEmpty { parts.append("\(leases.count) lease\(leases.count == 1 ? "" : "s")") }
        return "Awake — " + parts.joined(separator: " + ")
    }
}
