import Foundation

public struct SocketError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum UnixSocket {
    public static func connect(path: String, timeout: TimeInterval = 10) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket() failed: \(errnoString())") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard fill(path: path, into: &addr) else {
            close(fd)
            throw SocketError("Socket path too long")
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let err = errnoString()
            close(fd)
            throw SocketError("connect(\(path)) failed: \(err)")
        }
        setTimeout(fd, timeout)
        return fd
    }

    public static func bindListen(path: String, mode: mode_t) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket() failed: \(errnoString())") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard fill(path: path, into: &addr) else {
            close(fd)
            throw SocketError("Socket path too long")
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errnoString()
            close(fd)
            throw SocketError("bind(\(path)) failed: \(err)")
        }
        chmod(path, mode)
        guard listen(fd, 16) == 0 else {
            let err = errnoString()
            close(fd)
            throw SocketError("listen failed: \(err)")
        }
        return fd
    }

    public static func setTimeout(_ fd: Int32, _ timeout: TimeInterval) {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public static func sendAll(_ fd: Int32, _ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            while sent < data.count {
                let n = send(fd, raw.baseAddress!.advanced(by: sent), data.count - sent, 0)
                guard n > 0 else { throw SocketError("send failed: \(errnoString())") }
                sent += n
            }
        }
    }

    /// Reads until `terminator` is seen or EOF. Returns everything read (terminator included if found).
    public static func recvUntil(_ fd: Int32, terminator: Data, maxBytes: Int = 4 * 1024 * 1024) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count < maxBytes {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n < 0 { throw SocketError("recv failed: \(errnoString())") }
            if n == 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.range(of: terminator) != nil { break }
        }
        guard !buffer.isEmpty else { throw SocketError("Connection closed without response") }
        return buffer
    }

    private static func fill(path: String, into addr: inout sockaddr_un) -> Bool {
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            for (i, b) in bytes.enumerated() { dst[i] = b }
            dst[bytes.count] = 0
        }
        return true
    }

    private static func errnoString() -> String {
        String(cString: strerror(errno))
    }
}
