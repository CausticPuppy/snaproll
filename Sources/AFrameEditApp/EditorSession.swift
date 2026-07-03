import Foundation
import AFrameKit

/// Owns the connection and the editing conversation with the aFrame on a
/// background queue. UI talks to it from the main thread; events come back
/// on the main thread.
final class EditorSession {
    enum Event {
        case connected(firmware: String, group: GroupToneInfo)
        case disconnected
        case names(ToneSelect, [String])
        case toneLoaded(ToneSelect, num: Int, tone: ToneData)
        case saved(ToneSelect, num: Int)
        case meters(peak: PeakLevels, pressure: PressureLevels)
        case status(String)
        case error(String)
    }

    var onEvent: ((Event) -> Void)?

    private let queue = DispatchQueue(label: "aframe.serial", qos: .userInitiated)
    private var transport: AFrameTransport?
    private var client: AFrameClient?

    // Coalesced parameter writes: rapid slider drags collapse to the latest
    // value per parameter, flushed every ~20 ms.
    private struct ParamKey: Hashable {
        let sel: ToneSelect
        let index: Int
    }
    private var pendingWrites = [ParamKey: Int]()
    private var flushScheduled = false

    private(set) var isConnected = false

    // Real-time meter polling (~30 Hz). aFrame has no push channel, so live
    // pressure/level monitoring is a poll loop interleaved with edits on `queue`.
    private static let meterInterval = 1.0 / 30.0
    private var monitoring = false
    private var meterFailures = 0

    private func emit(_ event: Event) {
        DispatchQueue.main.async { self.onEvent?(event) }
    }

    // MARK: Lifecycle

    func connect(transport: AFrameTransport) {
        queue.async {
            do {
                try transport.open()
                let client = AFrameClient(transport: transport)
                client.responseTimeout = 1.5
                let firmware = try client.getVersion()
                try client.setExtMode(true)
                guard try client.getMode() == .editExt else {
                    throw AFrameError.notInExtEditMode
                }
                let info = try client.getCurrentGroupToneNum()
                self.transport = transport
                self.client = client
                self.isConnected = true
                self.emit(.connected(firmware: firmware, group: info))
                self.emit(.names(.instrument, try client.getProjectToneNameList(.instrument)))
                self.emit(.names(.effect, try client.getProjectToneNameList(.effect)))
                try self.loadTone(.instrument, num: info.instNum)
                try self.loadTone(.effect, num: info.effectNum)
            } catch {
                transport.close()
                self.emit(.error("Connection failed: \(error.localizedDescription)"))
            }
        }
    }

    func disconnect() {
        queue.async {
            if let client = self.client {
                try? client.setExtMode(false)
            }
            self.transport?.close()
            self.transport = nil
            self.client = nil
            self.isConnected = false
            self.monitoring = false
            self.emit(.disconnected)
        }
    }

    // MARK: Real-time monitoring

    /// Begins polling the input/output peak meters (aFG8) and pressure
    /// pitch/mute levels (aFG9), emitting `.meters` at ~30 Hz. No-op until
    /// connected; safe to call repeatedly.
    func startMonitoring() {
        queue.async {
            guard self.isConnected, !self.monitoring else { return }
            self.monitoring = true
            self.meterFailures = 0
            self.pollMeters()
        }
    }

    func stopMonitoring() {
        queue.async { self.monitoring = false }
    }

    private func pollMeters() {
        guard monitoring, isConnected, let client else { return }
        do {
            let peak = try client.getPeakLevel()
            let pressure = try client.getPressure()
            meterFailures = 0
            emit(.meters(peak: peak, pressure: pressure))
        } catch {
            // Tolerate the odd hiccup; give up after a few in a row so a dead
            // link doesn't keep stalling the queue for the response timeout.
            meterFailures += 1
            if meterFailures >= 3 {
                monitoring = false
                emit(.status("Monitoring stopped: \(error.localizedDescription)"))
                return
            }
        }
        queue.asyncAfter(deadline: .now() + Self.meterInterval) { [weak self] in
            self?.pollMeters()
        }
    }

    // MARK: Editing

    func selectTone(_ sel: ToneSelect, num: Int) {
        queue.async {
            guard let client = self.client else { return }
            do {
                try client.extChangeToneNum(sel, num: num)
                try self.loadTone(sel, num: num)
            } catch {
                self.emit(.error("Could not select tone \(num): \(error.localizedDescription)"))
            }
        }
    }

    func setParameter(_ sel: ToneSelect, index: Int, value: Int) {
        queue.async {
            self.pendingWrites[ParamKey(sel: sel, index: index)] = value
            self.scheduleFlush()
        }
    }

    func rename(_ sel: ToneSelect, to name: String) {
        queue.async {
            guard let client = self.client else { return }
            do {
                try client.extChangeEditBuffName(sel, name: String(name.prefix(DSPPatch.nameLength)))
                self.emit(.status("Renamed to “\(name)”"))
            } catch {
                self.emit(.error("Rename failed: \(error.localizedDescription)"))
            }
        }
    }

    /// Writes the edit buffer to the given project slot, then refreshes the
    /// name list so the sidebar reflects the save.
    func saveToProject(_ sel: ToneSelect, num: Int) {
        queue.async {
            guard let client = self.client else { return }
            do {
                self.flushNow()
                try client.extWriteEditBuffToProject(sel, num: num)
                self.emit(.saved(sel, num: num))
                self.emit(.names(sel, try client.getProjectToneNameList(sel)))
            } catch {
                self.emit(.error("Save failed: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: Internals (all on `queue`)

    private func loadTone(_ sel: ToneSelect, num: Int) throws {
        guard let client else { return }
        let (tone, _) = try client.extGetEditBuffText(sel)
        emit(.toneLoaded(sel, num: num, tone: tone))
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + 0.02) {
            self.flushScheduled = false
            self.flushNow()
        }
    }

    private func flushNow() {
        guard let client else { return }
        let writes = pendingWrites
        pendingWrites.removeAll()
        for (key, value) in writes {
            do {
                try client.extChangeEditBuffParam(key.sel, index: key.index, value: value)
            } catch AFrameError.commandRejected {
                emit(.error("Device rejected value \(value) for parameter \(key.index)"))
            } catch {
                emit(.error("Write failed: \(error.localizedDescription)"))
            }
        }
    }
}
