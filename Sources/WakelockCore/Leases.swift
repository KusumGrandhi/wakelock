import Foundation

/// Named, expiring leases held by scripts over the control socket.
/// The Mac stays awake while any lease is live; a lease that is not renewed
/// (re-acquired) before its TTL elapses is dropped.
public struct LeaseTable {
    public static let maxLeases = 256
    public static let maxTTL: TimeInterval = 86_400

    public private(set) var expiries: [String: Date] = [:]

    public init() {}

    public var isEmpty: Bool { expiries.isEmpty }
    public var count: Int { expiries.count }

    /// Acquire or renew (callers validate `ttl`, see CommandParser).
    /// Returns false only when the table is full and `id` is new.
    @discardableResult
    public mutating func acquire(_ id: String, ttl: TimeInterval, now: Date) -> Bool {
        if expiries[id] == nil && expiries.count >= Self.maxLeases { return false }
        expiries[id] = now.addingTimeInterval(ttl)
        return true
    }

    /// Returns whether a lease with that id existed.
    @discardableResult
    public mutating func release(_ id: String) -> Bool {
        expiries.removeValue(forKey: id) != nil
    }

    /// Drops every lease whose expiry is at or before `now`; returns the dropped ids.
    @discardableResult
    public mutating func expire(now: Date) -> [String] {
        let dead = expiries.filter { $0.value <= now }.map(\.key).sorted()
        for id in dead { expiries.removeValue(forKey: id) }
        return dead
    }

    /// Leases sorted by soonest expiry.
    public var sorted: [(id: String, expiry: Date)] {
        expiries.map { (id: $0.key, expiry: $0.value) }.sorted { $0.expiry < $1.expiry }
    }
}
