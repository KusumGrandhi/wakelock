import Foundation
import WakelockCore

// Minimal assertion runner: `swift run WakelockCoreTests`. Exits non-zero on failure.
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !condition() {
        failures += 1
        print("FAIL line \(line): \(message)")
    }
}

// MARK: CommandParser
check(CommandParser.parse("acquire build-1 600") == .success(.acquire(id: "build-1", ttl: 600)), "acquire parses")
check(CommandParser.parse("  ACQUIRE  a  5 ") == .success(.acquire(id: "a", ttl: 5)), "verb case/whitespace tolerant")
check(CommandParser.parse("release claude-abc.1") == .success(.release(id: "claude-abc.1")), "release parses")
check(CommandParser.parse("status") == .success(.status), "status parses")
check(CommandParser.parse("list") == .success(.list), "list parses")
check(CommandParser.parse("") == .failure(.empty), "empty rejected")
check(CommandParser.parse("sudo rm -rf /") == .failure(.unknown("sudo")), "unknown verb rejected")
check(CommandParser.parse("acquire x") == .failure(.usage("acquire <id> <ttl-seconds>")), "missing ttl")
check(CommandParser.parse("acquire x 0") == .failure(.badTTL), "ttl 0 rejected")
check(CommandParser.parse("acquire x -5") == .failure(.badTTL), "negative ttl rejected")
check(CommandParser.parse("acquire x 1.5") == .failure(.badTTL), "fractional ttl rejected")
check(CommandParser.parse("acquire x 86401") == .failure(.badTTL), "ttl over a day rejected")
check(CommandParser.parse("acquire a/b 60") == .failure(.badID), "slash in id rejected")
check(CommandParser.parse("acquire \(String(repeating: "a", count: 129)) 60") == .failure(.badID), "long id rejected")
check(CommandParser.parse("acquire \(String(repeating: "a", count: 128)) 60") != .failure(.badID), "128-char id accepted")
check(CommandParser.parse("acquire x 86400") == .success(.acquire(id: "x", ttl: 86400)), "ttl of exactly a day accepted")
check(CommandParser.parse("release") == .failure(.usage("release <id>")), "release without id rejected")
check(CommandParser.parse("status x") == .failure(.usage("status")), "status with args rejected")
check(CommandParser.parse("list x") == .failure(.usage("list")), "list with args rejected")

// MARK: LeaseTable
do {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var leases = LeaseTable()
    check(leases.acquire("a", ttl: 10, now: t0), "acquire a")
    check(leases.acquire("b", ttl: 30, now: t0), "acquire b")
    check(leases.expire(now: t0.addingTimeInterval(9)).isEmpty, "nothing expired at 9s")
    check(leases.acquire("a", ttl: 10, now: t0.addingTimeInterval(9)), "renew a")
    check(leases.expire(now: t0.addingTimeInterval(15)).isEmpty, "renewed lease survives original ttl")
    check(leases.expire(now: t0.addingTimeInterval(19)) == ["a"], "renewed lease expires at new ttl")
    check(leases.release("b"), "release b")
    check(!leases.release("b"), "double release reports missing")
    check(leases.isEmpty, "empty after release")

    var boundary = LeaseTable()
    boundary.acquire("x", ttl: 10, now: t0)
    check(boundary.expire(now: t0.addingTimeInterval(10)) == ["x"], "lease expires exactly at its ttl")

    var order = LeaseTable()
    order.acquire("late", ttl: 300, now: t0)
    order.acquire("soon", ttl: 5, now: t0)
    check(order.sorted.map(\.id) == ["soon", "late"], "sorted by soonest expiry")

    var full = LeaseTable()
    for i in 0..<LeaseTable.maxLeases { full.acquire("l\(i)", ttl: 60, now: t0) }
    check(!full.acquire("overflow", ttl: 60, now: t0), "table full rejects new id")
    check(full.acquire("l0", ttl: 60, now: t0), "table full still renews existing id")
}

// MARK: PMSetParser
let pmsetG = """
System-wide power settings:
 SleepDisabled\t\t1
Currently in use:
 standby              0
 sleep                0 (sleep prevented by Wakelock)
"""
check(PMSetParser.sleepDisabled(fromPmsetG: pmsetG) == true, "SleepDisabled 1")
check(PMSetParser.sleepDisabled(fromPmsetG: pmsetG.replacingOccurrences(of: "\t\t1", with: "\t\t0")) == false, "SleepDisabled 0")
check(PMSetParser.sleepDisabled(fromPmsetG: "System-wide power settings:\nCurrently in use:\n sleep 1\n") == false,
      "line omitted (real pmset behaviour when 0) -> false")
check(PMSetParser.sleepDisabled(fromPmsetG: "") == nil, "unrecognised output -> nil")


// MARK: SafetyPolicy
func inputs(pct: Int? = 80, battery: Bool = true, floor: Int = 20, lpm: Bool = false,
            thermal: ProcessInfo.ThermalState = .nominal) -> SafetyInputs {
    SafetyInputs(batteryPercent: pct, onBatteryPower: battery, batteryFloor: floor, lowPowerMode: lpm, thermalState: thermal)
}
check(SafetyPolicy.blockReason(inputs()) == nil, "healthy -> allowed")
check(SafetyPolicy.blockReason(inputs(pct: 19)) != nil, "below floor on battery -> blocked")
check(SafetyPolicy.blockReason(inputs(pct: 20)) == nil, "at floor -> allowed")
check(SafetyPolicy.blockReason(inputs(pct: 5, battery: false)) == nil, "below floor on AC -> allowed")
check(SafetyPolicy.blockReason(inputs(pct: nil)) == nil, "no battery -> allowed")
check(SafetyPolicy.blockReason(inputs(lpm: true)) != nil, "low power mode -> blocked")
check(SafetyPolicy.blockReason(inputs(thermal: .fair)) == nil, "thermal fair -> allowed")
check(SafetyPolicy.blockReason(inputs(thermal: .serious)) != nil, "thermal serious -> blocked")
check(SafetyPolicy.blockReason(inputs(thermal: .critical)) != nil, "thermal critical -> blocked")

// MARK: ManualSession / WakePolicy
do {
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    var session = ManualSession()
    session.start(duration: 900, now: t0)
    session.update(now: t0.addingTimeInterval(899), blockReason: nil)
    check(session.isOn, "session on before expiry")
    session.update(now: t0.addingTimeInterval(900), blockReason: nil)
    check(!session.isOn && session.autoOffReason == "Timer finished", "session ends at expiry")

    session.start(duration: nil, now: t0)
    check(session.autoOffReason == nil, "start clears auto-off reason")
    session.update(now: t0.addingTimeInterval(1e7), blockReason: nil)
    check(session.isOn, "indefinite session never expires")
    session.update(now: t0, blockReason: "Low Power Mode is on")
    check(!session.isOn && session.autoOffReason == "Turned off: Low Power Mode is on", "block turns session off")
    session.update(now: t0, blockReason: nil)
    check(!session.isOn, "session stays off after block clears")

    check(WakePolicy.wantAwake(manualOn: true, hasLeases: false, blockReason: nil), "manual -> awake")
    check(WakePolicy.wantAwake(manualOn: false, hasLeases: true, blockReason: nil), "lease -> awake")
    check(!WakePolicy.wantAwake(manualOn: false, hasLeases: false, blockReason: nil), "nothing -> off")
    check(!WakePolicy.wantAwake(manualOn: true, hasLeases: true, blockReason: "hot"), "block overrides everything")

    check(WakePolicy.format(3900) == "1h 05m", "format hours")
    check(WakePolicy.format(119) == "1m", "format minutes")
    check(WakePolicy.format(0.2) == "1s", "format rounds partial seconds up")
    check(WakePolicy.format(-5) == "0s", "format clamps negatives")
}

if failures == 0 {
    print("All WakelockCore checks passed.")
} else {
    print("\(failures) check(s) failed.")
    exit(1)
}
