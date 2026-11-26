import Darwin
import Foundation

public struct BridgeReadyInfo: Sendable {
    public let displayId: Int32
    public let width: Int32
    public let height: Int32
}

public enum BridgeError: LocalizedError {
    case connectFailed(String)
    case handshakeFailed(String)
    case remoteError(String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .connectFailed(let s): return L10n.t("显示桥接连接失败：\(s)", "Display bridge connection failed: \(s)")
        case .handshakeFailed(let s): return L10n.t("显示会话初始化失败：\(s)", "Display session setup failed: \(s)")
        case .remoteError(let s): return L10n.t("Android 窗口服务错误：\(s)", "Android window service error: \(s)")
        case .closed: return L10n.t("窗口连接已断开", "Window connection closed")
        }
    }
}

public protocol BridgeClientDelegate: AnyObject {
    func bridge(_ client: BridgeClient, didReceiveConfig data: Data)
    func bridge(_ client: BridgeClient, didReceiveFrame data: Data, ptsUs: Int64, isKeyframe: Bool)
    func bridge(_ client: BridgeClient, didResize width: Int32, height: Int32)
    func bridge(_ client: BridgeClient, didClose error: Error?)
}

public final class BridgeClient: @unchecked Sendable {
    private static let magic: UInt32 = 0x414D4353 // "AMCS"
    private static let version: UInt8 = 1

    private enum S2C: UInt8 {
        case ready = 0x01
        case codecConfig = 0x02
        case videoFrame = 0x03
        case resized = 0x04
        case error = 0x05
    }

    private enum C2S: UInt8 {
        case touch = 0x10
        case scroll = 0x11
        case key = 0x12
        case text = 0x13
        case resize = 0x14
        case syncFrame = 0x15
        case clipboard = 0x16
        case close = 0x17
    }

    public weak var delegate: BridgeClientDelegate?

    private let host: String
    private let port: UInt16
    private let ioLock = NSLock()
    private var fd: Int32 = -1
    private var closed = false
    private var readerThread: Thread?

    public private(set) var displayId: Int32 = -1
    public private(set) var width: Int32 = 0
    public private(set) var height: Int32 = 0

    public init(host: String = "127.0.0.1", port: UInt16 = 15576) {
        self.host = host
        self.port = port
    }

    deinit { disconnect() }

    public func open(mode: ChannelMode, width: Int32, height: Int32, dpi: Int32, bitrate: Int32 = 8_000_000, fps: Int32 = 60) async throws -> BridgeReadyInfo {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let sock = try self.dial(host: self.host, port: self.port)
                    self.ioLock.lock()
                    self.fd = sock
                    self.closed = false
                    self.ioLock.unlock()

                    var hello = Data(capacity: 26)
                    self.putBE(Self.magic, into: &hello)
                    hello.append(Self.version)
                    hello.append(mode.rawValue)
                    self.putBE(width, into: &hello)
                    self.putBE(height, into: &hello)
                    self.putBE(dpi, into: &hello)
                    self.putBE(bitrate, into: &hello)
                    self.putBE(fps, into: &hello)
                    try self.sendAll(fd: sock, data: hello)

                    let (kind, body) = try self.recvPacket(fd: sock)
                    if kind == S2C.error.rawValue {
                        self.disconnect()
                        throw BridgeError.remoteError(String(data: body, encoding: .utf8) ?? "Unknown")
                    }
                    guard kind == S2C.ready.rawValue, body.count >= 12 else {
                        self.disconnect()
                        throw BridgeError.handshakeFailed("Unexpected packet \(kind)")
                    }

                    let dId = self.int32BE(body, 0)
                    let w = self.int32BE(body, 4)
                    let h = self.int32BE(body, 8)
                    self.displayId = dId
                    self.width = w
                    self.height = h

                    let t = Thread { [weak self] in self?.readLoop(fd: sock) }
                    t.name = "BridgeReader-\(dId)"
                    t.qualityOfService = .userInteractive
                    self.readerThread = t
                    t.start()

                    cont.resume(returning: BridgeReadyInfo(displayId: dId, width: w, height: h))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func touch(action: UInt8, pointerId: Int32 = 0, x: Float, y: Float) {
        var p = Data(capacity: 13)
        p.append(action)
        putBE(pointerId, into: &p)
        putBE(x.bitPattern, into: &p)
        putBE(y.bitPattern, into: &p)
        enqueue(.touch, payload: p)
    }

    public func scroll(x: Float, y: Float, dx: Float, dy: Float) {
        var p = Data(capacity: 16)
        putBE(x.bitPattern, into: &p)
        putBE(y.bitPattern, into: &p)
        putBE(dx.bitPattern, into: &p)
        putBE(dy.bitPattern, into: &p)
        enqueue(.scroll, payload: p)
    }

    public func key(action: UInt8, code: Int32, meta: Int32 = 0) {
        var p = Data(capacity: 9)
        p.append(action)
        putBE(code, into: &p)
        putBE(meta, into: &p)
        enqueue(.key, payload: p)
    }

    public func tapKey(_ code: Int32, meta: Int32 = 0) {
        key(action: 0, code: code, meta: meta)
        key(action: 1, code: code, meta: meta)
    }

    public func text(_ string: String) {
        guard let d = string.data(using: .utf8), !d.isEmpty else { return }
        enqueue(.text, payload: d)
    }

    public func pasteClipboard(_ string: String) {
        guard let utf8 = string.data(using: .utf8) else { return }
        var p = Data(capacity: 1 + utf8.count)
        p.append(1)
        p.append(utf8)
        enqueue(.clipboard, payload: p)
    }

    public func resize(width: Int32, height: Int32, dpi: Int32) {
        var p = Data(capacity: 12)
        putBE(width, into: &p)
        putBE(height, into: &p)
        putBE(dpi, into: &p)
        enqueue(.resize, payload: p)
    }

    public func requestSyncFrame() {
        enqueue(.syncFrame, payload: Data())
    }

    public func disconnect() {
        ioLock.lock()
        if closed {
            ioLock.unlock()
            return
        }
        closed = true
        let sock = fd
        fd = -1
        if sock >= 0 {
            var bye = Data(capacity: 5)
            bye.append(C2S.close.rawValue)
            putBE(Int32(0), into: &bye)
            _ = try? sendAll(fd: sock, data: bye)
            Darwin.shutdown(sock, SHUT_RDWR)
            Darwin.close(sock)
        }
        ioLock.unlock()
    }

    private func enqueue(_ cmd: C2S, payload: Data) {
        var pkt = Data(capacity: 5 + payload.count)
        pkt.append(cmd.rawValue)
        putBE(Int32(payload.count), into: &pkt)
        pkt.append(payload)

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            self.ioLock.lock()
            let sock = self.fd
            if !self.closed && sock >= 0 {
                _ = try? self.sendAll(fd: sock, data: pkt)
            }
            self.ioLock.unlock()
        }
    }

    private func readLoop(fd: Int32) {
        var err: Error?
        while true {
            do {
                let (kind, body) = try recvPacket(fd: fd)
                switch kind {
                case S2C.codecConfig.rawValue:
                    delegate?.bridge(self, didReceiveConfig: body)
                case S2C.videoFrame.rawValue:
                    guard body.count > 12 else { continue }
                    let flags = int32BE(body, 0)
                    let pts = int64BE(body, 4)
                    delegate?.bridge(self, didReceiveFrame: body.subdata(in: 12..<body.count), ptsUs: pts, isKeyframe: (flags & 1) != 0)
                case S2C.resized.rawValue:
                    guard body.count >= 8 else { continue }
                    let w = int32BE(body, 0)
                    let h = int32BE(body, 4)
                    self.width = w
                    self.height = h
                    delegate?.bridge(self, didResize: w, height: h)
                case S2C.error.rawValue:
                    err = BridgeError.remoteError(String(data: body, encoding: .utf8) ?? "Error")
                    break
                default:
                    break
                }
            } catch {
                ioLock.lock()
                let intentional = closed
                ioLock.unlock()
                if !intentional { err = error }
                break
            }
        }
        disconnect()
        delegate?.bridge(self, didClose: err)
    }

    private func dial(host: String, port: UInt16) throws -> Int32 {
        let s = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw BridgeError.connectFailed("socket errno \(errno)") }
        var one: Int32 = 1
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)

        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            let e = errno
            Darwin.close(s)
            throw BridgeError.connectFailed("connect errno \(e)")
        }
        return s
    }

    private func sendAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    throw BridgeError.closed
                }
                sent += n
            }
        }
    }

    private func recvExact(fd: Int32, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var buf = Data(count: count)
        try buf.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < count {
                let n = Darwin.recv(fd, base.advanced(by: off), count - off, 0)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    throw BridgeError.closed
                }
                off += n
            }
        }
        return buf
    }

    private func recvPacket(fd: Int32) throws -> (UInt8, Data) {
        let hdr = try recvExact(fd: fd, count: 5)
        let len = Int(int32BE(hdr, 1))
        guard len >= 0 && len <= 32 * 1024 * 1024 else {
            throw BridgeError.handshakeFailed("Bad length \(len)")
        }
        return (hdr[0], try recvExact(fd: fd, count: len))
    }

    private func putBE<T: FixedWidthInteger>(_ val: T, into data: inout Data) {
        var be = val.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private func int32BE(_ d: Data, _ o: Int) -> Int32 {
        let v = (UInt32(d[o]) << 24) | (UInt32(d[o + 1]) << 16) | (UInt32(d[o + 2]) << 8) | UInt32(d[o + 3])
        return Int32(bitPattern: v)
    }

    private func int64BE(_ d: Data, _ o: Int) -> Int64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(d[o + i]) }
        return Int64(bitPattern: v)
    }
}
