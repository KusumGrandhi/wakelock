import Foundation

/// The user's manual keep-awake session: on/off, optional end time, and the
/// reason it last switched itself off.
public struct ManualSession {
    public private(set) var isOn = false
    public private(set) var expiry: Date?
    public private(set) var autoOffReason: String?

    public init() {}

    /// `duration` nil means indefinitely.
    public mutating func start(duration: TimeInterval?, now: Date) {
        isOn = true
        expiry = duration.map { now.addingTimeInterval($0) }
        autoOffReason = nil
    }

    public mutating func stop() {
        isOn = false
        expiry = nil
    }

    /// Ends the session when its timer has run out or a safety block applies.
    /// A session ended this way stays off until the user starts it again.
    public mutating func update(now: Date, blockReason: String?) {
        guard isOn else { return }
        if let blockReason {
            stop()
            autoOffReason = "Turned off: \(blockReason)"
        } else if let expiry, expiry <= now {
            stop()
            autoOffReason = "Timer finished"
        }
    }
}

public enum WakePolicy {
    /// Awake while the manual session is on or any lease is live, unless blocked.
    public static func wantAwake(manualOn: Bool, hasLeases: Bool, blockReason: String?) -> Bool {
        (manualOn || hasLeases) && blockReason == nil
    }

    /// "1h 05m", "42m", "30s".
    public static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        if s >= 3600 { return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60) }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }
}
