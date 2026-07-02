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
            self.emit(.disconnected)
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
