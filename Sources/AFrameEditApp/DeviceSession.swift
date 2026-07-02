import Foundation
import AFrameKit

/// Owns the serial connection on a background queue and exposes
/// main-thread-callback APIs to the UI.
final class DeviceSession {
    struct Status {
        var mode: AFrameMode
        var peaks: PeakLevels
        var pressure: PressureLevels
        var lcdLine1: String
        var lcdLine2: String
    }

    private let queue = DispatchQueue(label: "aframe.serial", qos: .userInitiated)
    private var transport: AFrameTransport?
    private var client: AFrameClient?
    private var pollInFlight = false

    var isConnected: Bool { client != nil }

    func connect(transport: AFrameTransport, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            do {
                try transport.open()
                let client = AFrameClient(transport: transport)
                client.responseTimeout = 1.0
                let version = try client.getVersion()
                self.transport = transport
                self.client = client
                DispatchQueue.main.async { completion(.success(version)) }
            } catch {
                transport.close()
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func disconnect() {
        queue.async {
            self.transport?.close()
            self.transport = nil
            self.client = nil
        }
    }

    func pollStatus(completion: @escaping (Result<Status, Error>) -> Void) {
        queue.async {
            guard let client = self.client, !self.pollInFlight else { return }
            self.pollInFlight = true
            defer { self.pollInFlight = false }
            do {
                let status = Status(
                    mode: try client.getMode(),
                    peaks: try client.getPeakLevel(),
                    pressure: try client.getPressure(),
                    lcdLine1: try client.getLCD(addr: 0, count: 16),
                    lcdLine2: try client.getLCD(addr: 32, count: 16))
                DispatchQueue.main.async { completion(.success(status)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}
