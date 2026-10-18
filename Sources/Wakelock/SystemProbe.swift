import Foundation
import IOKit
import IOKit.ps

struct BatteryInfo: Equatable {
    var percent: Int?        // nil when the Mac has no internal battery
    var onBatteryPower: Bool
}

enum SystemProbe {
    static func battery() -> BatteryInfo {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return BatteryInfo(percent: nil, onBatteryPower: false) }

        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let onBattery = providing == "Battery Power"

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  desc["Type"] as? String == "InternalBattery",
                  let current = desc["Current Capacity"] as? Int,
                  let max = desc["Max Capacity"] as? Int, max > 0
            else { continue }
            return BatteryInfo(percent: current * 100 / max, onBatteryPower: onBattery)
        }
        return BatteryInfo(percent: nil, onBatteryPower: onBattery)
    }

    /// True when the built-in display's lid is closed; nil on Macs without a lid.
    static func lidClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }
}
