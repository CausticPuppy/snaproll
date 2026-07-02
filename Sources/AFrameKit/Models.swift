import Foundation

// MARK: - Enums (API spec Appendix A / Fig 6, Fig 11)

public enum AFrameMode: Int, CaseIterable, CustomStringConvertible {
    case home = 0
    case editInstSE = 1
    case editEffectSE = 2
    case editInst = 3
    case editEffect = 4
    case groupSelect = 5
    case levelInput = 6
    case levelOutput = 7
    case system = 8
    case editExt = 9

    public var description: String {
        switch self {
        case .home: return "HOME"
        case .editInstSE: return "EDIT_INST_SE"
        case .editEffectSE: return "EDIT_EFFECT_SE"
        case .editInst: return "EDIT_INST"
        case .editEffect: return "EDIT_EFFECT"
        case .groupSelect: return "GROUP_SELECT"
        case .levelInput: return "LEVEL_INPUT"
        case .levelOutput: return "LEVEL_OUTPUT"
        case .system: return "SYSTEM"
        case .editExt: return "EDIT_EXT"
        }
    }
}

public enum ToneSelect: Int {
    case instrument = 0
    case effect = 1
}

/// Groups A–D, A′–D′ (values 0–7 per Fig 13).
public enum ToneGroup: Int, CaseIterable, CustomStringConvertible {
    case a = 0, b, c, d, aP, bP, cP, dP
    public var description: String {
        ["A", "B", "C", "D", "A'", "B'", "C'", "D'"][rawValue]
    }
}

// MARK: - Simple value types

public struct PeakLevels: Equatable {
    public var inCenter: Int
    public var inEdge: Int
    public var outL: Int
    public var outR: Int
    public init(inCenter: Int, inEdge: Int, outL: Int, outR: Int) {
        self.inCenter = inCenter
        self.inEdge = inEdge
        self.outL = outL
        self.outR = outR
    }
}

public struct PressureLevels: Equatable {
    public var pitch: Int
    public var mute: Int
    public init(pitch: Int, mute: Int) {
        self.pitch = pitch
        self.mute = mute
    }
}

/// Response of GetCurrentGroupToneNum (aFGA).
public struct GroupToneInfo: Equatable {
    public var group: Int
    public var number: Int
    public var max: Int
    public var instNum: Int
    public var effectNum: Int
    public init(group: Int, number: Int, max: Int, instNum: Int, effectNum: Int) {
        self.group = group
        self.number = number
        self.max = max
        self.instNum = instNum
        self.effectNum = effectNum
    }
}

/// One (instrument, effect) slot of a group (DSP_MEMORY).
public struct GroupSlot: Equatable {
    public var inst: Int
    public var effect: Int
    public init(inst: Int, effect: Int) {
        self.inst = inst
        self.effect = effect
    }
}

/// Response of GetProjectGroupList (aFGD): active max + 40 slots.
public struct GroupList: Equatable {
    public var max: Int
    public var slots: [GroupSlot]
    public init(max: Int, slots: [GroupSlot]) {
        self.max = max
        self.slots = slots
    }
}

/// Tone data as returned by aFGC/aFGF and the TXT mode of aFE6.
public struct ToneData: Equatable {
    public var algoNum: Int
    public var name: String
    public var values: [Int]
    public init(algoNum: Int, name: String, values: [Int]) {
        self.algoNum = algoNum
        self.name = name
        self.values = values
    }
}

// MARK: - DSP_PATCH (Appendix C, 192 bytes)

public struct DSPPatch: Equatable {
    public static let byteSize = 192
    public static let dataCount = 84
    public static let nameLength = 20

    public var algoNum: Int16
    public var name: String
    public var prmNum: Int16
    public var data: [Int16]  // always 84 entries

    public init(algoNum: Int16 = 0, name: String = "", prmNum: Int16 = 0,
                data: [Int16] = Array(repeating: 0, count: DSPPatch.dataCount)) {
        self.algoNum = algoNum
        self.name = name
        self.prmNum = prmNum
        var d = data
        if d.count != DSPPatch.dataCount {
            d = Array((d + Array(repeating: 0, count: DSPPatch.dataCount)).prefix(DSPPatch.dataCount))
        }
        self.data = d
    }

    /// Little-endian byte layout is assumed (to be verified against a capture).
    public func encode() -> Data {
        var out = Data(capacity: DSPPatch.byteSize)
        out.appendLE(algoNum)
        out.appendFixedString(name, length: DSPPatch.nameLength)
        out.appendLE(prmNum)
        for v in data { out.appendLE(v) }
        return out
    }

    public static func decode(_ bytes: Data) throws -> DSPPatch {
        guard bytes.count >= byteSize else { throw AFrameError.malformedResponse("DSP_PATCH too short: \(bytes.count)") }
        var r = BinaryReader(bytes)
        let algo: Int16 = r.readLE()
        let name = r.readFixedString(nameLength)
        let prm: Int16 = r.readLE()
        var data = [Int16]()
        data.reserveCapacity(dataCount)
        for _ in 0..<dataCount { data.append(r.readLE()) }
        return DSPPatch(algoNum: algo, name: name, prmNum: prm, data: data)
    }

    // MARK: aFE6/aFE7 transfer format
    //
    // The BIN edit-buffer payload is variable-length (verified against a
    // VER.2.00 device): algo(i16) + name[20] + prm_num(i16) + data[prm_num]
    // + byteSum16 checksum, all little-endian. 184 bytes for a 79-parameter
    // instrument, 72 for a 23-parameter effect.

    /// Serializes to the aFE7 upload payload, appending the checksum.
    public func encodeTransfer() -> Data {
        var out = Data(capacity: 24 + Int(prmNum) * 2 + 2)
        out.appendLE(algoNum)
        out.appendFixedString(name, length: DSPPatch.nameLength)
        out.appendLE(prmNum)
        for v in data.prefix(Int(prmNum)) { out.appendLE(v) }
        out.appendLE(Checksums.byteSum16(out))
        return out
    }

    /// Parses an aFE6 BIN payload, verifying size and checksum.
    public static func decodeTransfer(_ bytes: Data) throws -> DSPPatch {
        guard bytes.count >= 26 else {
            throw AFrameError.malformedResponse("edit buffer payload too short: \(bytes.count)")
        }
        var r = BinaryReader(bytes)
        let algo: Int16 = r.readLE()
        let name = r.readFixedString(nameLength)
        let prm: Int16 = r.readLE()
        guard prm >= 0, prm <= Int16(dataCount), bytes.count == 24 + Int(prm) * 2 + 2 else {
            throw AFrameError.malformedResponse(
                "edit buffer payload size \(bytes.count) does not match prm_num \(prm)")
        }
        let computed = Checksums.byteSum16(bytes.prefix(bytes.count - 2))
        var tail = BinaryReader(bytes.suffix(2))
        let stored: UInt16 = tail.readLE()
        guard computed == stored else {
            throw AFrameError.checksumMismatch(expected: UInt32(computed), actual: UInt32(stored))
        }
        var data = [Int16]()
        for _ in 0..<Int(prm) { data.append(r.readLE()) }
        return DSPPatch(algoNum: algo, name: name, prmNum: prm, data: data)
    }
}

// MARK: - DSP_PROJECT (Appendix C, 0x7F00 bytes)

public struct DSPProject: Equatable {
    public static let byteSize = 0x7F00
    public static let patchCount = 80
    public static let memoryGroups = 8
    public static let memorySlots = 40

    public var id: Int32
    public var name: String            // 28 bytes
    public var signature: String       // 24 bytes
    public var instPatchSel: Int16
    public var effectPatchSel: Int16
    public var instPatchMax: Int16
    public var effectPatchMax: Int16
    public var instPatch: [DSPPatch]   // 80
    public var effectPatch: [DSPPatch] // 80
    public var memory: [[GroupSlot]]   // [8][40]
    public var memoryGrp: Int16
    public var memoryNum: Int16
    public var memoryMax: [Int16]      // 8

    public init(
        id: Int32 = 0,
        name: String = "NewProject",
        signature: String = "",
        instPatchSel: Int16 = 0,
        effectPatchSel: Int16 = 0,
        instPatchMax: Int16 = Int16(DSPProject.patchCount),
        effectPatchMax: Int16 = Int16(DSPProject.patchCount),
        instPatch: [DSPPatch] = Array(repeating: DSPPatch(), count: DSPProject.patchCount),
        effectPatch: [DSPPatch] = Array(repeating: DSPPatch(), count: DSPProject.patchCount),
        memory: [[GroupSlot]] = Array(
            repeating: Array(repeating: GroupSlot(inst: 0, effect: 0), count: DSPProject.memorySlots),
            count: DSPProject.memoryGroups),
        memoryGrp: Int16 = 0,
        memoryNum: Int16 = 0,
        memoryMax: [Int16] = Array(repeating: 10, count: DSPProject.memoryGroups)
    ) {
        self.id = id
        self.name = name
        self.signature = signature
        self.instPatchSel = instPatchSel
        self.effectPatchSel = effectPatchSel
        self.instPatchMax = instPatchMax
        self.effectPatchMax = effectPatchMax
        self.instPatch = instPatch
        self.effectPatch = effectPatch
        self.memory = memory
        self.memoryGrp = memoryGrp
        self.memoryNum = memoryNum
        self.memoryMax = memoryMax
    }

    /// Serializes to the full 0x7F00 image, computing the trailing checksum.
    /// Checksum algorithm (32-bit sum of preceding bytes) is a working
    /// hypothesis until verified against a device capture.
    public func encode() -> Data {
        var out = Data(capacity: DSPProject.byteSize)
        out.appendLE(id)
        out.appendFixedString(name, length: 28)
        out.appendFixedString(signature, length: 24)
        out.appendLE(instPatchSel)
        out.appendLE(effectPatchSel)
        out.appendLE(instPatchMax)
        out.appendLE(effectPatchMax)
        for p in instPatch { out.append(p.encode()) }
        for p in effectPatch { out.append(p.encode()) }
        for g in memory {
            for s in g {
                out.appendLE(Int16(s.inst))
                out.appendLE(Int16(s.effect))
            }
        }
        out.appendLE(memoryGrp)
        out.appendLE(memoryNum)
        for m in memoryMax { out.appendLE(m) }
        out.append(Data(repeating: 0, count: 424))  // chDummy
        out.appendLE(Int32(bitPattern: Checksums.byteSum32(out)))
        precondition(out.count == DSPProject.byteSize)
        return out
    }

    public static func decode(_ bytes: Data, verifyChecksum: Bool = true) throws -> DSPProject {
        guard bytes.count >= byteSize else {
            throw AFrameError.malformedResponse("DSP_PROJECT too short: \(bytes.count) bytes")
        }
        if verifyChecksum {
            var tail = BinaryReader(bytes.suffix(4))
            let stored = tail.readLEUInt32()
            let computed = Checksums.byteSum32(bytes.prefix(byteSize - 4))
            guard stored == computed else {
                throw AFrameError.checksumMismatch(expected: computed, actual: stored)
            }
        }
        var r = BinaryReader(bytes)
        let id: Int32 = r.readLE()
        let name = r.readFixedString(28)
        let signature = r.readFixedString(24)
        let instSel: Int16 = r.readLE()
        let fxSel: Int16 = r.readLE()
        let instMax: Int16 = r.readLE()
        let fxMax: Int16 = r.readLE()
        var inst = [DSPPatch]()
        var fx = [DSPPatch]()
        for _ in 0..<patchCount { inst.append(try DSPPatch.decode(r.readData(DSPPatch.byteSize))) }
        for _ in 0..<patchCount { fx.append(try DSPPatch.decode(r.readData(DSPPatch.byteSize))) }
        var memory = [[GroupSlot]]()
        for _ in 0..<memoryGroups {
            var g = [GroupSlot]()
            for _ in 0..<memorySlots {
                let p1: Int16 = r.readLE()
                let p2: Int16 = r.readLE()
                g.append(GroupSlot(inst: Int(p1), effect: Int(p2)))
            }
            memory.append(g)
        }
        let grp: Int16 = r.readLE()
        let num: Int16 = r.readLE()
        var maxes = [Int16]()
        for _ in 0..<memoryGroups { maxes.append(r.readLE()) }
        return DSPProject(
            id: id, name: name, signature: signature,
            instPatchSel: instSel, effectPatchSel: fxSel,
            instPatchMax: instMax, effectPatchMax: fxMax,
            instPatch: inst, effectPatch: fx, memory: memory,
            memoryGrp: grp, memoryNum: num, memoryMax: maxes)
    }
}

// MARK: - Checksums

public enum Checksums {
    /// 16-bit truncated sum of bytes. Working hypothesis for the aFE6/aFE7
    /// binary edit-buffer checksum — verify against a capture.
    public static func byteSum16(_ data: Data) -> UInt16 {
        var s: UInt32 = 0
        for b in data { s &+= UInt32(b) }
        return UInt16(truncatingIfNeeded: s)
    }

    /// 32-bit truncated sum of bytes. Working hypothesis for the DSP_PROJECT
    /// trailing checksum.
    public static func byteSum32(_ data: Data) -> UInt32 {
        var s: UInt32 = 0
        for b in data { s &+= UInt32(b) }
        return s
    }

    /// Sum of the numeric fields of a TXT-mode tone dump (algo + params),
    /// truncated to 16 bits. Hypothesis for the aFE6 TXT checksum line
    /// (spec example: "5117") — verify against a capture.
    public static func txtToneSum(algoNum: Int, values: [Int]) -> Int {
        var s = algoNum
        for v in values { s &+= v }
        return s & 0xFFFF
    }
}

// MARK: - Binary helpers

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendFixedString(_ s: String, length: Int) {
        var bytes = Array(s.utf8.prefix(length))
        bytes += Array(repeating: 0, count: length - bytes.count)
        append(contentsOf: bytes)
    }
}

struct BinaryReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = Data(data)  // rebase indices to 0
        self.offset = 0
    }

    mutating func readLE<T: FixedWidthInteger>() -> T {
        let size = MemoryLayout<T>.size
        var v: T = 0
        _ = withUnsafeMutableBytes(of: &v) { dest in
            data.copyBytes(to: dest, from: offset..<(offset + size))
        }
        offset += size
        return T(littleEndian: v)
    }

    mutating func readLEUInt32() -> UInt32 { readLE() }

    mutating func readFixedString(_ length: Int) -> String {
        let slice = data.subdata(in: offset..<(offset + length))
        offset += length
        let trimmed = slice.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    mutating func readData(_ count: Int) -> Data {
        let slice = data.subdata(in: offset..<(offset + count))
        offset += count
        return slice
    }
}
