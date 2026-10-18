import Foundation

/// Conditions under which Wakelock refuses to keep the Mac awake.
public struct SafetyInputs {
    public var batteryPercent: Int?      // nil on Macs without a battery
    public var onBatteryPower: Bool
    public var batteryFloor: Int
    public var lowPowerMode: Bool
    public var thermalState: ProcessInfo.ThermalState

    public init(batteryPercent: Int?, onBatteryPower: Bool, batteryFloor: Int,
                lowPowerMode: Bool, thermalState: ProcessInfo.ThermalState) {
        self.batteryPercent = batteryPercent
        self.onBatteryPower = onBatteryPower
        self.batteryFloor = batteryFloor
        self.lowPowerMode = lowPowerMode
        self.thermalState = thermalState
    }
}

public enum SafetyPolicy {
    /// Returns a human-readable reason to force sleep-prevention off, or nil if it's safe.
    /// The battery floor only applies while running on battery power: below the floor
    /// on AC the battery is charging, and holding the Mac awake can't drain it.
    public static func blockReason(_ i: SafetyInputs) -> String? {
        if i.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            return "thermal state \(i.thermalState == .critical ? "critical" : "serious")"
        }
        if i.lowPowerMode {
            return "Low Power Mode is on"
        }
        if i.onBatteryPower, let pct = i.batteryPercent, pct < i.batteryFloor {
            return "battery \(pct)% is below the \(i.batteryFloor)% floor"
        }
        return nil
    }
}
