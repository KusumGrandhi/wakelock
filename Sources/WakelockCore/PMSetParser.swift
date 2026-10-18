import Foundation

/// Parses `pmset -g` output so the menu can show the
/// system's real state rather than what the app believes it set.
public enum PMSetParser {
    /// `pmset -g` prints ` SleepDisabled		1` under "System-wide power settings:"
    /// when sleep is disabled, and omits the line entirely when it is not.
    /// Returns nil only when the output doesn't look like `pmset -g` at all.
    public static func sleepDisabled(fromPmsetG output: String) -> Bool? {
        if let v = value(named: "SleepDisabled", in: output) { return v != 0 }
        return output.contains("System-wide power settings:") ? false : nil
    }


    private static func value(named key: String, in output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2, fields[0] == key, let v = Int(fields[1]) { return v }
        }
        return nil
    }
}
