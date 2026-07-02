import Foundation
import Darwin

/// Byte-level transport to an aFrame. Real hardware uses `POSIXSerialPort`;
/// tests and offline development use `MockAFrame`.
public protocol AFrameTransport: AnyObject {
    func open() throws
    func close()
    func write(_ data: Data) throws
    /// Returns at least one byte, waiting up to `timeout`. Throws `.timeout` if nothing arrives.
    func read(maxLength: Int, timeout: TimeInterval) throws -> Data
}

public enum AFrameTransportError: Error, LocalizedError, Equatable {
    case openFailed(path: String, errno: Int32)
    case notOpen
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path, let err):
            return "Could not open \(path): \(String(cString: strerror(err)))"
        case .notOpen:
            return "Port is not open"
        case .writeFailed(let err):
            return "Write failed: \(String(cString: strerror(err)))"
        case .readFailed(let err):
            return "Read failed: \(String(cString: strerror(err)))"
        case .timeout:
            return "Timed out waiting for data from the aFrame"
        }
    }
}

/// Serial port via POSIX termios. aFrame spec: CP2102 VCP, 115200 8N1, no handshake.
public final class POSIXSerialPort: AFrameTransport {
    public let path: String
    private var fd: Int32 = -1

    public init(path: String) {
        self.path = path
    }

    deinit { close() }

    public func open() throws {
        guard fd < 0 else { return }
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            throw AFrameTransportError.openFailed(path: path, errno: errno)
        }

        var tty = termios()
        tcgetattr(fd, &tty)
        cfmakeraw(&tty)
        cfsetspeed(&tty, speed_t(B115200))
        tty.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tty.c_cflag &= ~tcflag_t(PARENB)                      // no parity
        tty.c_cflag &= ~tcflag_t(CSTOPB)                      // 1 stop bit
        tty.c_cflag &= ~tcflag_t(CSIZE)
        tty.c_cflag |= tcflag_t(CS8)                          // 8 data bits
        tty.c_cflag &= ~tcflag_t(CCTS_OFLOW | CRTS_IFLOW)     // no hardware handshake
        tcsetattr(fd, TCSANOW, &tty)
        tcflush(fd, TCIOFLUSH)
    }

    public func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    public func write(_ data: Data) throws {
        guard fd >= 0 else { throw AFrameTransportError.notOpen }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n > 0 {
                    offset += n
                } else if errno == EAGAIN {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    poll(&pfd, 1, 1000)
                } else {
                    throw AFrameTransportError.writeFailed(errno: errno)
                }
            }
        }
    }

    public func read(maxLength: Int, timeout: TimeInterval) throws -> Data {
        guard fd >= 0 else { throw AFrameTransportError.notOpen }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let rc = poll(&pfd, 1, Int32(max(0, timeout * 1000)))
        if rc == 0 { throw AFrameTransportError.timeout }
        if rc < 0 { throw AFrameTransportError.readFailed(errno: errno) }

        var buf = [UInt8](repeating: 0, count: maxLength)
        let n = Darwin.read(fd, &buf, maxLength)
        if n > 0 { return Data(buf[0..<n]) }
        if n == 0 || errno == EAGAIN { throw AFrameTransportError.timeout }
        throw AFrameTransportError.readFailed(errno: errno)
    }
}

/// Discovers candidate serial devices for the aFrame's CP2102 bridge.
public enum SerialPortDiscovery {
    /// All callout devices, most-likely-aFrame first. With the Silicon Labs VCP
    /// driver the CP2102 appears as `cu.SLAB_USBtoUART`; with the macOS built-in
    /// driver it appears as `cu.usbserial-*` (or `cu.usbmodem*`).
    public static func candidatePorts() -> [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let ports = all.filter { $0.hasPrefix("cu.") }.map { "/dev/" + $0 }
        func rank(_ p: String) -> Int {
            if p.contains("SLAB") { return 0 }
            if p.contains("usbserial") { return 1 }
            if p.contains("usbmodem") { return 2 }
            if p.contains("Bluetooth") || p.contains("debug") { return 9 }
            return 5
        }
        return ports.sorted { (rank($0), $0) < (rank($1), $1) }
    }
}
