import Foundation

/// One line of the control-socket protocol.
///
///     acquire <id> <ttl-seconds>   take or renew a lease
///     release <id>                 drop a lease
///     status                       one-line machine-readable state
///     list                         one line per live lease
public enum Command: Equatable {
    case acquire(id: String, ttl: TimeInterval)
    case release(id: String)
    case status
    case list
}

public enum CommandError: Error, Equatable, CustomStringConvertible {
    case empty
    case unknown(String)
    case usage(String)
    case badID
    case badTTL

    public var description: String {
        switch self {
        case .empty: return "empty command"
        case .unknown(let verb): return "unknown command '\(verb)' (expected acquire|release|status|list)"
        case .usage(let usage): return "usage: \(usage)"
        case .badID: return "id must be 1-128 chars of [A-Za-z0-9._:@-]"
        case .badTTL: return "ttl must be an integer number of seconds, 1-\(Int(LeaseTable.maxTTL))"
        }
    }
}

public enum CommandParser {
    private static let idChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:@-")

    public static func isValidID(_ id: String) -> Bool {
        (1...128).contains(id.count) && id.allSatisfy(idChars.contains)
    }

    public static func parse(_ line: String) -> Result<Command, CommandError> {
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let verb = parts.first?.lowercased() else { return .failure(.empty) }
        let args = Array(parts.dropFirst())

        switch verb {
        case "acquire":
            guard args.count == 2 else { return .failure(.usage("acquire <id> <ttl-seconds>")) }
            guard isValidID(args[0]) else { return .failure(.badID) }
            guard let ttl = Int(args[1]), ttl >= 1, TimeInterval(ttl) <= LeaseTable.maxTTL else {
                return .failure(.badTTL)
            }
            return .success(.acquire(id: args[0], ttl: TimeInterval(ttl)))
        case "release":
            guard args.count == 1 else { return .failure(.usage("release <id>")) }
            guard isValidID(args[0]) else { return .failure(.badID) }
            return .success(.release(id: args[0]))
        case "status":
            return args.isEmpty ? .success(.status) : .failure(.usage("status"))
        case "list":
            return args.isEmpty ? .success(.list) : .failure(.usage("list"))
        default:
            return .failure(.unknown(verb))
        }
    }
}
