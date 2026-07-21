import Foundation
import Darwin

public enum SocketError: Error { case create(Int32), bind(Int32), listen(Int32), connect(Int32) }

/// Fill a sockaddr_un for `path`. AF_UNIX path is capped at 104 bytes on Darwin.
private func makeAddr(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { raw in
        raw.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
            strncpy(dst, path, 103)
        }
    }
    return addr
}

private let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

/// Read one newline-terminated line (without the newline) from `fd`, or nil on EOF/error.
private func readLine(fd: Int32) -> String? {
    var data = Data()
    var byte: UInt8 = 0
    while true {
        let n = read(fd, &byte, 1)
        if n <= 0 { return data.isEmpty ? nil : String(data: data, encoding: .utf8) }
        if byte == 0x0a { return String(data: data, encoding: .utf8) }
        data.append(byte)
    }
}

private func writeAll(fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        var off = 0
        let base = raw.bindMemory(to: UInt8.self).baseAddress!
        while off < data.count {
            let n = write(fd, base + off, data.count - off)
            if n <= 0 { return }
            off += n
        }
    }
}

// MARK: - Server (app side)

/// Accepts hook connections. Handler runs on a per-connection background thread and
/// MAY block (a PermissionRequest handler blocks until the user decides); returning a
/// Decision writes it back to the hook. Return nil for fire-and-forget events.
/// ponytail: naive thread-per-connection; fine for a few local agents. Upgrade to a
/// dispatch source if connection volume ever grows.
public final class UnixSocketServer: @unchecked Sendable {
    private let path: String
    private var listenFD: Int32 = -1
    private var running = false

    public init(path: String) { self.path = path }

    public func start(handler: @escaping @Sendable (HookMessage) -> Decision?) throws {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.create(errno) }
        var addr = makeAddr(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, addrLen) }
        }
        guard bound == 0 else { close(fd); throw SocketError.bind(errno) }
        guard listen(fd, 16) == 0 else { close(fd); throw SocketError.listen(errno) }
        listenFD = fd
        running = true
        Thread.detachNewThread { [weak self] in self?.acceptLoop(handler) }
    }

    public func stop() {
        running = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private func acceptLoop(_ handler: @escaping @Sendable (HookMessage) -> Decision?) {
        while running {
            let client = accept(listenFD, nil, nil)
            if client < 0 { if running { continue } else { break } }
            Thread.detachNewThread { [weak self] in self?.serve(client, handler) }
        }
    }

    private func serve(_ client: Int32, _ handler: @escaping @Sendable (HookMessage) -> Decision?) {
        defer { close(client) }
        guard let line = readLine(fd: client),
              let msg = try? JSONDecoder().decode(HookMessage.self, from: Data(line.utf8))
        else { return }
        if let decision = handler(msg) {
            if var out = try? JSONEncoder().encode(decision) {
                out.append(0x0a)
                writeAll(fd: client, out)
            }
        }
    }
}

// MARK: - Client (hook side)

public enum SocketClient {
    /// Send one message. If `awaitDecisionTimeout` > 0, block up to that long for a
    /// Decision reply. Returns the Decision, or nil (no reply / timeout / app absent).
    /// Never throws: if the app isn't running we fail open (nil) so the agent proceeds.
    public static func send(_ message: HookMessage, to path: String,
                            awaitDecisionTimeout: TimeInterval = 0) -> Decision? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = makeAddr(path)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, addrLen) }
        }
        guard connected == 0 else { return nil }        // app not running -> fail open

        guard var data = try? JSONEncoder().encode(message) else { return nil }
        data.append(0x0a)
        writeAll(fd: fd, data)

        guard awaitDecisionTimeout > 0 else { return nil }

        // Enforce our own deadline (hook timeout fails OPEN, so we must not rely on it).
        var tv = timeval(tv_sec: Int(awaitDecisionTimeout),
                         tv_usec: Int32((awaitDecisionTimeout.truncatingRemainder(dividingBy: 1)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard let line = readLine(fd: fd),
              let decision = try? JSONDecoder().decode(Decision.self, from: Data(line.utf8))
        else { return nil }
        return decision
    }
}
