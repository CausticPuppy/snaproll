import Foundation

public enum AFrameError: Error, LocalizedError, Equatable {
    case commandRejected(command: String, code: Int)   // device answered 1:NG
    case notInExtEditMode                              // device answered -1
    case dataPhaseFailed(DataPhaseResult)
    case malformedResponse(String)
    case checksumMismatch(expected: UInt32, actual: UInt32)

    public var errorDescription: String? {
        switch self {
        case .commandRejected(let cmd, let code):
            return "aFrame rejected \(cmd) (result \(code))"
        case .notInExtEditMode:
            return "aFrame is not in external edit mode (send SetExtModeSw first)"
        case .dataPhaseFailed(let r):
            return "Data transfer failed: \(r)"
        case .malformedResponse(let s):
            return "Malformed response: \(s)"
        case .checksumMismatch(let e, let a):
            return String(format: "Checksum mismatch (expected %08X, got %08X)", e, a)
        }
    }
}

/// Result codes of the aFE7/aFE9 data phase.
public enum DataPhaseResult: Int, CustomStringConvertible {
    case ok = 0
    case timeout = 1
    case dataSizeError = 2
    case checksumError = 3

    public var description: String {
        switch self {
        case .ok: return "OK"
        case .timeout: return "TIME_OUT"
        case .dataSizeError: return "DATA_SIZE_ERR"
        case .checksumError: return "CHECK_SUM_ERR"
        }
    }
}

/// Edit-buffer transfer encoding for aFE6/aFE7.
///
/// The spec's tables say "0:BIN 2:TXT" while its body text says "mode1(TXT)";
/// hardware testing (VER.2.00) confirmed the tables: TXT is 2.
public enum BuffMode: Int {
    case bin = 0
    case txt = 2
}

/// Synchronous client for the aFrame serial API (spec Ver 1.10).
/// Not thread-safe: confine each instance to one queue.
public final class AFrameClient {
    public let transport: AFrameTransport
    public var responseTimeout: TimeInterval = 2.0
    /// Extra patience for bulk transfers (project ~32 KB at 115200 baud ≈ 3 s+).
    public var bulkTimeout: TimeInterval = 30.0
    /// Wire value used for TXT mode (see `BuffMode`).
    public var txtModeValue = BuffMode.txt.rawValue

    private var rxBuffer = Data()

    public init(transport: AFrameTransport) {
        self.transport = transport
    }

    // MARK: - Framing

    public func send(_ command: String) throws {
        try transport.write(Data((command + "\r\n").utf8))
    }

    public func readLine(timeout: TimeInterval? = nil) throws -> String {
        let deadline = Date().addingTimeInterval(timeout ?? responseTimeout)
        while true {
            if let nl = rxBuffer.firstIndex(of: 0x0A) {
                var line = rxBuffer.subdata(in: rxBuffer.startIndex..<nl)
                rxBuffer.removeSubrange(rxBuffer.startIndex...nl)
                if line.last == 0x0D { line.removeLast() }
                return String(decoding: line, as: UTF8.self)
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw AFrameTransportError.timeout }
            rxBuffer.append(try transport.read(maxLength: 4096, timeout: remaining))
        }
    }

    public func readExact(_ count: Int, timeout: TimeInterval? = nil) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout ?? bulkTimeout)
        while rxBuffer.count < count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw AFrameTransportError.timeout }
            rxBuffer.append(try transport.read(maxLength: 65536, timeout: remaining))
        }
        let out = rxBuffer.prefix(count)
        rxBuffer.removeFirst(count)
        return Data(out)
    }

    /// Reads a line and parses the leading integer. Tolerates both "0" and
    /// "0:OK" shaped replies (the spec is ambiguous about the suffix).
    func readIntLine(timeout: TimeInterval? = nil) throws -> Int {
        let line = try readLine(timeout: timeout)
        let head = line.prefix { $0 == "-" || $0.isNumber }
        guard let v = Int(head) else {
            throw AFrameError.malformedResponse("expected integer, got \"\(line)\"")
        }
        return v
    }

    func readCSVInts(timeout: TimeInterval? = nil) throws -> [Int] {
        let line = try readLine(timeout: timeout)
        return try AFrameClient.parseCSVInts(line)
    }

    /// Parses a comma-separated value line. Real firmware terminates data
    /// lines with a trailing comma, and the spec's TXT example shows empty
    /// fields mid-list; drop a trailing empty field, read interior empties
    /// as 0, and reject anything else non-numeric.
    static func parseCSVInts(_ line: String) throws -> [Int] {
        var parts = line.split(separator: ",", omittingEmptySubsequences: false)
        if parts.last == "" { parts.removeLast() }
        return try parts.map {
            let t = $0.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return 0 }
            guard let v = Int(t) else {
                throw AFrameError.malformedResponse("expected int list, got \"\(line)\"")
            }
            return v
        }
    }

    /// Discards any unread bytes (e.g. the tail of an interrupted bulk
    /// response) by reading until the line stays quiet. Call before sending
    /// a command after an error to resynchronize the stream.
    public func drain(quietPeriod: TimeInterval = 0.3) {
        rxBuffer.removeAll()
        while let chunk = try? transport.read(maxLength: 65536, timeout: quietPeriod), !chunk.isEmpty {
            continue  // keep discarding until a quiet period elapses
        }
    }

    /// Sends a command that answers 0:OK / 1:NG (optionally -1: not EDIT_EXT).
    func performSimple(_ command: String) throws {
        try send(command)
        let code = try readIntLine()
        switch code {
        case 0: return
        case -1: throw AFrameError.notInExtEditMode
        default: throw AFrameError.commandRejected(command: command, code: code)
        }
    }

    private func lcdFlag(_ lcd: Bool) -> String { lcd ? "1" : "0" }

    // MARK: - Get functions (aFG0–aFGF)

    public func getVersion() throws -> String {
        try send("aFG0")
        return try readLine()
    }

    public func getMode() throws -> AFrameMode {
        try send("aFG1")
        let v = try readIntLine()
        guard let mode = AFrameMode(rawValue: v) else {
            throw AFrameError.malformedResponse("unknown mode \(v)")
        }
        return mode
    }

    public func getSwitch() throws -> UInt16 {
        try send("aFG2")
        return UInt16(truncatingIfNeeded: try readIntLine())
    }

    public func getEncoder() throws -> Int16 {
        try send("aFG3")
        return Int16(truncatingIfNeeded: try readIntLine())
    }

    public func getLED() throws -> UInt32 {
        try send("aFG4")
        return UInt32(truncatingIfNeeded: try readIntLine())
    }

    public func getLCD(addr: Int, count: Int) throws -> String {
        try send("aFG5:\(addr),\(count)")
        return try readLine()
    }

    public func getGroupBank() throws -> Int {
        try send("aFG6")
        return try readIntLine()
    }

    public func getGroupNum() throws -> Int {
        try send("aFG7")
        return try readIntLine()
    }

    public func getPeakLevel() throws -> PeakLevels {
        try send("aFG8")
        let v = try readCSVInts()
        guard v.count == 4 else { throw AFrameError.malformedResponse("aFG8: \(v)") }
        return PeakLevels(inCenter: v[0], inEdge: v[1], outL: v[2], outR: v[3])
    }

    public func getPressure() throws -> PressureLevels {
        try send("aFG9")
        let v = try readCSVInts()
        guard v.count == 2 else { throw AFrameError.malformedResponse("aFG9: \(v)") }
        return PressureLevels(pitch: v[0], mute: v[1])
    }

    public func getCurrentGroupToneNum() throws -> GroupToneInfo {
        try send("aFGA")
        let v = try readCSVInts()
        guard v.count == 5 else { throw AFrameError.malformedResponse("aFGA: \(v)") }
        return GroupToneInfo(group: v[0], number: v[1], max: v[2], instNum: v[3], effectNum: v[4])
    }

    /// Returns ("I62:Basstronics", "E62:BasstrPhaser") style raw lines.
    public func getCurrentToneName() throws -> (inst: String, effect: String) {
        try send("aFGB")
        let a = try readLine()
        let b = try readLine()
        return (a, b)
    }

    public func getCurrentToneData(_ sel: ToneSelect) throws -> ToneData {
        try send("aFGC:\(sel.rawValue)")
        return try readToneDataBlock()
    }

    public func getProjectGroupList(group: Int) throws -> GroupList {
        try send("aFGD:\(group)")
        let head = try readLine()
        // Header "Gmax:<n>"
        guard let colon = head.firstIndex(of: ":"), let max = Int(head[head.index(after: colon)...]) else {
            throw AFrameError.malformedResponse("aFGD header: \"\(head)\"")
        }
        var slots = [GroupSlot]()
        for _ in 0..<DSPProject.memorySlots {
            let v = try readCSVInts()
            guard v.count == 2 else { throw AFrameError.malformedResponse("aFGD row: \(v)") }
            slots.append(GroupSlot(inst: v[0], effect: v[1]))
        }
        return GroupList(max: max, slots: slots)
    }

    public func getProjectToneNameList(_ sel: ToneSelect) throws -> [String] {
        try send("aFGE:\(sel.rawValue)")
        return try (0..<DSPProject.patchCount).map { _ in try readLine() }
    }

    public func getProjectToneData(_ sel: ToneSelect, num: Int) throws -> ToneData {
        try send("aFGF:\(sel.rawValue),\(num)")
        return try readToneDataBlock()
    }

    public func getProjectToneDataList(_ sel: ToneSelect) throws -> [ToneData] {
        try send("aFGF:\(sel.rawValue),-1")
        return try (0..<DSPProject.patchCount).map { _ in try readToneDataBlock() }
    }

    /// Like `getProjectToneDataList` but returns the 320 raw response lines
    /// verbatim (4 per tone), for capture forensics.
    public func getProjectToneDataListVerbatim(_ sel: ToneSelect) throws -> [String] {
        try send("aFGF:\(sel.rawValue),-1")
        return try (0..<(DSPProject.patchCount * 4)).map { _ in try readLine() }
    }

    /// Reads the 4-line algo/name/prm_num/data block shared by aFGC/aFGF.
    private func readToneDataBlock() throws -> ToneData {
        guard let algo = Int(try readLine()) else {
            throw AFrameError.malformedResponse("tone data: bad algo_num")
        }
        let name = try readLine()
        guard let prmNum = Int(try readLine()) else {
            throw AFrameError.malformedResponse("tone data: bad prm_num")
        }
        let values = try readCSVInts()
        guard values.count >= prmNum else {
            throw AFrameError.malformedResponse("tone data: \(values.count) values, expected \(prmNum)")
        }
        return ToneData(algoNum: algo, name: name, values: Array(values.prefix(prmNum)))
    }

    // MARK: - Set functions (aFS1–aFS7)

    public func setExtMode(_ on: Bool) throws {
        try performSimple("aFS1:\(on ? 1 : 0)")
    }

    public func setSwitch(_ value: UInt16) throws {
        try performSimple("aFS2:\(value)")
    }

    public func setEncoder(_ value: Int16) throws {
        try performSimple("aFS3:\(value)")
    }

    public func setLED(_ value: UInt32) throws {
        try performSimple("aFS4:\(value)")
    }

    public func setLCD(addr: Int, text: String) throws {
        try performSimple("aFS5:\(addr),\(text)")
    }

    public func setGroupBank(up: Bool) throws {
        try performSimple("aFS6:\(up ? 1 : 0)")
    }

    public func setGroupNum(up: Bool) throws {
        try performSimple("aFS7:\(up ? 1 : 0)")
    }

    // MARK: - External editing functions (aFE0–aFE9)

    public func extSelectGroup(group: Int, num: Int, lcd: Bool = false) throws {
        try performSimple("aFE0:\(group),\(num),\(lcdFlag(lcd))")
    }

    public func extWriteGroup(group: Int, num: Int, max: Int, lcd: Bool = false) throws {
        try performSimple("aFE1:\(group),\(num),\(max),\(lcdFlag(lcd))")
    }

    public func extChangeToneNum(_ sel: ToneSelect, num: Int, lcd: Bool = false) throws {
        try performSimple("aFE2:\(sel.rawValue),\(num),\(lcdFlag(lcd))")
    }

    public func extChangeEditBuffParam(_ sel: ToneSelect, index: Int, value: Int, lcd: Bool = false) throws {
        try performSimple("aFE3:\(sel.rawValue),\(index),\(value),\(lcdFlag(lcd))")
    }

    public func extChangeEditBuffName(_ sel: ToneSelect, name: String, lcd: Bool = false) throws {
        try performSimple("aFE4:\(sel.rawValue),\(lcdFlag(lcd)),\(name)")
    }

    public func extWriteEditBuffToProject(_ sel: ToneSelect, num: Int, lcd: Bool = false) throws {
        try performSimple("aFE5:\(sel.rawValue),\(num),\(lcdFlag(lcd))")
    }

    /// Fetches and parses the edit buffer in binary form (checksum-verified).
    public func extGetEditBuff(_ sel: ToneSelect, lcd: Bool = false) throws -> DSPPatch {
        try DSPPatch.decodeTransfer(try extGetEditBuffBinary(sel, lcd: lcd))
    }

    /// Uploads a patch to the edit buffer in binary form.
    public func extSetEditBuff(_ sel: ToneSelect, patch: DSPPatch, lcd: Bool = false) throws {
        try extSetEditBuffBinary(sel, payload: patch.encodeTransfer(), lcd: lcd)
    }

    /// Fetches the raw edit buffer payload: 2-byte LE size prefix on the wire,
    /// then `size` bytes (variable length; last two bytes are the checksum).
    public func extGetEditBuffBinary(_ sel: ToneSelect, lcd: Bool = false) throws -> Data {
        try send("aFE6:\(sel.rawValue),\(BuffMode.bin.rawValue),\(lcdFlag(lcd))")
        let sizeBytes = try readExact(2, timeout: responseTimeout)
        let size = Int(sizeBytes[sizeBytes.startIndex]) | (Int(sizeBytes[sizeBytes.index(after: sizeBytes.startIndex)]) << 8)
        guard size > 2, size <= 4096 else {
            // A "-1\r\n" (not EDIT_EXT) reply would land here as an absurd size.
            throw AFrameError.notInExtEditMode
        }
        return try readExact(size)
    }

    /// Fetches the edit buffer as a TXT dump (algo/name/prm_num/data/checksum).
    public func extGetEditBuffText(_ sel: ToneSelect, lcd: Bool = false) throws -> (tone: ToneData, checksumLine: String) {
        try send("aFE6:\(sel.rawValue),\(txtModeValue),\(lcdFlag(lcd))")
        let first = try readLine()
        if first == "-1" { throw AFrameError.notInExtEditMode }
        guard let algo = Int(first) else {
            throw AFrameError.malformedResponse("aFE6 TXT: bad algo line \"\(first)\"")
        }
        let name = try readLine()
        guard let prmNum = Int(try readLine()) else {
            throw AFrameError.malformedResponse("aFE6 TXT: bad prm_num")
        }
        // Data lines may contain empty fields (spec example: "50,0,,,,...,64,").
        let values = try AFrameClient.parseCSVInts(try readLine())
        let checksum = try readLine()
        return (ToneData(algoNum: algo, name: name, values: Array(values.prefix(max(prmNum, 0)))), checksum)
    }

    /// Two-phase upload of a binary edit buffer (aFE7).
    public func extSetEditBuffBinary(_ sel: ToneSelect, payload: Data, lcd: Bool = false) throws {
        try send("aFE7:\(sel.rawValue),\(BuffMode.bin.rawValue),\(lcdFlag(lcd))")
        let ready = try readIntLine()
        guard ready == 0 else { throw AFrameError.notInExtEditMode }
        var frame = Data()
        frame.appendLE(UInt16(payload.count))
        frame.append(payload)
        try transport.write(frame)
        let result = try readIntLine(timeout: bulkTimeout)
        guard let phase = DataPhaseResult(rawValue: result), phase == .ok else {
            throw AFrameError.dataPhaseFailed(DataPhaseResult(rawValue: result) ?? .timeout)
        }
    }

    /// Downloads the whole project (LZSS-encoded payload; caller decodes).
    public func extGetProjectRaw(waitMs: Int = 0, lcd: Bool = false) throws -> Data {
        try send("aFE8:\(waitMs),\(lcdFlag(lcd))")
        let sizeBytes = try readExact(2, timeout: responseTimeout)
        let size = Int(sizeBytes[sizeBytes.startIndex]) | (Int(sizeBytes[sizeBytes.index(after: sizeBytes.startIndex)]) << 8)
        guard size > 0 else { throw AFrameError.malformedResponse("aFE8: zero size") }
        return try readExact(size)
    }

    /// Two-phase upload of an LZSS-encoded project image (aFE9).
    public func extSetProjectRaw(_ encoded: Data, lcd: Bool = false) throws {
        try send("aFE9:\(lcdFlag(lcd))")
        let ready = try readIntLine()
        guard ready == 0 else { throw AFrameError.notInExtEditMode }
        var frame = Data()
        frame.appendLE(UInt16(encoded.count))
        frame.append(encoded)
        try transport.write(frame)
        let result = try readIntLine(timeout: bulkTimeout)
        guard let phase = DataPhaseResult(rawValue: result), phase == .ok else {
            throw AFrameError.dataPhaseFailed(DataPhaseResult(rawValue: result) ?? .timeout)
        }
    }

    // MARK: - Conveniences

    /// Downloads and decodes the whole project.
    public func extGetProject(waitMs: Int = 0, lcd: Bool = false, verifyChecksum: Bool = true) throws -> DSPProject {
        let raw = try extGetProjectRaw(waitMs: waitMs, lcd: lcd)
        let decoded = try AFrameLZ.decode(framed: raw)
        return try DSPProject.decode(decoded, verifyChecksum: verifyChecksum)
    }

    /// Encodes and uploads a whole project.
    public func extSetProject(_ project: DSPProject, lcd: Bool = false) throws {
        try extSetProjectRaw(AFrameLZ.encode(framed: project.encode()), lcd: lcd)
    }
}
