import Darwin
import Foundation

enum Paths {
    static let socket = NSHomeDirectory() + "/Library/Application Support/Wakelock/sock"
}

/// Unix-domain socket server. One command per connection: the client writes a
/// line, gets one reply line, and the server closes. That keeps `nc -U` simple.
/// Only processes running as the same uid may talk to it (dir 0700, socket 0600,
/// plus a getpeereid check).
final class LeaseServer {
    typealias Handler = @MainActor (String) -> String

    enum ServerError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case posix(String, Int32)
        var description: String {
            switch self {
            case .pathTooLong(let p): return "socket path too long: \(p)"
            case .posix(let call, let err): return "\(call): \(String(cString: strerror(err)))"
            }
        }
    }

    private let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "wakelock.socket.accept")
    private let clientQueue = DispatchQueue(label: "wakelock.socket.client", attributes: .concurrent)

    init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        chmod(dir, 0o700)
        unlink(path)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw ServerError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.posix("socket", errno) }

        let oldMask = umask(0o077)  // socket file is created 0600, no window where it's wider
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard rc == 0 else { let e = errno; close(fd); throw ServerError.posix("bind", e) }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { let e = errno; close(fd); throw ServerError.posix("listen", e) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        src.setEventHandler { [weak self] in self?.acceptPending() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }  // EAGAIN: drained
            clientQueue.async { [weak self] in
                if let self { self.serve(client) } else { close(client) }
            }
        }
    }

    /// Reads on a client thread, answers on main without blocking that thread,
    /// then writes back on the client queue.
    private func serve(_ fd: Int32) {
        guard let line = readCommand(fd) else { close(fd); return }
        let handler = self.handler, clientQueue = self.clientQueue
        DispatchQueue.main.async {
            let reply = MainActor.assumeIsolated { handler(line) }
            clientQueue.async {
                let out = Array((reply + "\n").utf8)
                out.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
                close(fd)
            }
        }
    }

    /// One trimmed line from a same-uid peer, or nil to drop the connection.
    private func readCommand(_ fd: Int32) -> String? {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)  // accepted fds inherit O_NONBLOCK on BSD
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return nil }

        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 256)
        while buffer.count < 1024 {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer += chunk[0..<n]
            if buffer.contains(UInt8(ascii: "\n")) { break }
        }
        return String(decoding: buffer.prefix { $0 != UInt8(ascii: "\n") }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
