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
        case projectSaved(name: String, url: URL)
        case projectLoaded(name: String, backup: URL?)
        case groups(list: [GroupList], current: GroupToneInfo)
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
                try self.loadNamesAndCurrentTones(info)
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
    /// name list so the tone browser reflects the save.
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

    // MARK: Project load / save

    /// Pulls the whole project from the device and writes it to `url` as the
    /// decoded 0x7F00 image (the same `.prj` format legacy aFrameEdit uses).
    func saveProject(to url: URL) {
        queue.async {
            guard let client = self.client else {
                self.emit(.error("Connect to an aFrame before saving a project"))
                return
            }
            do {
                self.flushNow()
                let image = try AFrameLZ.decode(framed: try client.extGetProjectRaw())
                let name = (try? DSPProject.decode(image, verifyChecksum: false))?.name ?? ""
                try image.write(to: url)
                self.emit(.projectSaved(name: name, url: url))
            } catch {
                self.emit(.error("Project save failed: \(error.localizedDescription)"))
            }
        }
    }

    /// Reads a `.prj` image file, validates it, backs up the device's current
    /// project, then uploads the file — replacing the entire device project.
    /// Refuses (without touching the device) if the file is malformed or the
    /// safety backup can't be written.
    func loadProject(from url: URL) {
        queue.async {
            guard let client = self.client else {
                self.emit(.error("Connect to an aFrame before loading a project"))
                return
            }
            do {
                let image = try Data(contentsOf: url)
                let project = try DSPProject.decode(image)  // validates size + checksum
                let backup = try self.writeAutoBackup(client: client)
                try client.extSetProjectRaw(AFrameLZ.encode(framed: image))
                self.emit(.projectLoaded(name: project.name, backup: backup))
                let info = try client.getCurrentGroupToneNum()
                try self.loadNamesAndCurrentTones(info)
            } catch {
                self.emit(.error("Project load failed: \(error.localizedDescription)"))
            }
        }
    }

    /// Saves the device's current project into the app-support Backups folder,
    /// returning the file URL. Throws if it can't be written (so a load that
    /// promised a backup aborts before overwriting anything).
    private func writeAutoBackup(client: AFrameClient) throws -> URL {
        let image = try AFrameLZ.decode(framed: try client.extGetProjectRaw())
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("aFrame Edit/Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("autobackup-\(fmt.string(from: Date())).prj")
        try image.write(to: url)
        return url
    }

    // MARK: Group map

    /// Reads all 8 groups and the current position, emitting `.groups`.
    func loadGroups() {
        queue.async {
            guard let client = self.client else {
                self.emit(.error("Connect to an aFrame to edit groups"))
                return
            }
            do { try self.emitGroups(client) }
            catch { self.emit(.error("Group load failed: \(error.localizedDescription)")) }
        }
    }

    /// Recalls a group slot on the device (loads its inst+effect), then refreshes
    /// the editor to the newly-loaded tones.
    func recallGroupSlot(group: Int, num: Int) {
        queue.async {
            guard let client = self.client else { return }
            do {
                self.flushNow()
                try client.extSelectGroup(group: group, num: num)
                try self.refreshCurrentTones(client)
                try self.emitGroups(client)
                self.emit(.status("Recalled \(Self.groupLabel(group))-\(String(format: "%02d", num + 1))"))
            } catch {
                self.emit(.error("Recall failed: \(error.localizedDescription)"))
            }
        }
    }

    /// Writes the current inst+effect selection into a group slot, preserving the
    /// group's MAX.
    func storeCurrentToGroup(group: Int, num: Int, max: Int) {
        queue.async {
            guard let client = self.client else { return }
            do {
                self.flushNow()
                try client.extWriteGroup(group: group, num: num, max: max)
                try self.emitGroups(client)
                self.emit(.status("Stored current selection to \(Self.groupLabel(group))-\(String(format: "%02d", num + 1))"))
            } catch {
                self.emit(.error("Store failed: \(error.localizedDescription)"))
            }
        }
    }

    /// Sets a group's MAX. Since aFE1 is the only MAX setter and it also rewrites
    /// a slot with the current selection, this recalls slot 0, stores it back
    /// unchanged with the new MAX, then returns to the prior position.
    func setGroupMax(group: Int, max: Int) {
        queue.async {
            guard let client = self.client else { return }
            do {
                self.flushNow()
                let prior = try client.getCurrentGroupToneNum()
                try client.extSelectGroup(group: group, num: 0)
                try client.extWriteGroup(group: group, num: 0, max: max)
                try client.extSelectGroup(group: prior.group, num: prior.number)
                try self.refreshCurrentTones(client)
                try self.emitGroups(client)
                self.emit(.status("Set \(Self.groupLabel(group)) MAX to \(max)"))
            } catch {
                self.emit(.error("Set MAX failed: \(error.localizedDescription)"))
            }
        }
    }

    private func emitGroups(_ client: AFrameClient) throws {
        let current = try client.getCurrentGroupToneNum()
        var lists = [GroupList]()
        for g in 0..<DSPProject.memoryGroups {
            lists.append(try client.getProjectGroupList(group: g))
        }
        emit(.groups(list: lists, current: current))
    }

    private func refreshCurrentTones(_ client: AFrameClient) throws {
        let info = try client.getCurrentGroupToneNum()
        try loadTone(.instrument, num: info.instNum)
        try loadTone(.effect, num: info.effectNum)
    }

    private static func groupLabel(_ g: Int) -> String {
        ToneGroup(rawValue: g)?.description ?? "\(g)"
    }

    // MARK: Internals (all on `queue`)

    private func loadTone(_ sel: ToneSelect, num: Int) throws {
        guard let client else { return }
        let (tone, _) = try client.extGetEditBuffText(sel)
        emit(.toneLoaded(sel, num: num, tone: tone))
    }

    /// Re-reads the project tone-name lists and the current inst/effect tones
    /// (shared by connect and project-load).
    private func loadNamesAndCurrentTones(_ info: GroupToneInfo) throws {
        guard let client else { return }
        emit(.names(.instrument, try client.getProjectToneNameList(.instrument)))
        emit(.names(.effect, try client.getProjectToneNameList(.effect)))
        try loadTone(.instrument, num: info.instNum)
        try loadTone(.effect, num: info.effectNum)
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
