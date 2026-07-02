import Foundation

/// In-memory simulation of an aFrame implementing the Ver 1.10 API over the
/// transport interface. Semantics follow the spec's "Execution Result"
/// pseudocode; wire details that the spec leaves ambiguous mirror the
/// hypotheses documented in `AFrameClient`/`Checksums` so that client + mock
/// stay consistent until real captures settle them.
public final class MockAFrame: AFrameTransport {

    // MARK: Device state

    public var project: DSPProject
    public private(set) var mode: AFrameMode = .home
    public var instPatchEdit: DSPPatch
    public var effectPatchEdit: DSPPatch
    public var switchState: UInt16 = 0
    public var encoder: Int16 = 0
    public var led: UInt32 = 0
    public var lcd = [UInt8](repeating: 0x20, count: 64)

    private var inBuffer = Data()
    private var outBuffer = Data()
    private var meterPhase = 0

    /// Pending two-phase upload (aFE7 / aFE9).
    private enum PendingUpload {
        case editBuff(ToneSelect)
        case project
    }
    private var pending: PendingUpload?

    // MARK: Init

    public init(project: DSPProject? = nil) {
        let p = project ?? MockAFrame.demoProject()
        self.project = p
        self.instPatchEdit = p.instPatch[Int(p.instPatchSel)]
        self.effectPatchEdit = p.effectPatch[Int(p.effectPatchSel)]
    }

    /// A plausible factory-style project for UI development.
    public static func demoProject() -> DSPProject {
        let instNames = [
            "SnappyFramey", "GrowlingPot", "3D MadTemple", "SpankBass", "DeepSeaGong",
            "WonderBell", "TutTutDrum", "MetaGamelan", "AquaForest", "VentD'Orient",
            "LogPrimitive", "TaikoTribe", "DrumNative", "DrumInfinity", "Framey3D",
            "Goblet Drum2", "HyperKanjira", "ScatterDrums", "PuppyBell", "StompBlues",
        ]
        let fxNames = [
            "SnapFrameRev", "GrowlPotRev", "SpaceZMadTem", "SpankB.Rev", "DeepSebGgRev",
            "WonderBelRev", "TuTuDrmDly", "MetaGamelDly", "AquaFrstTDLY", "Ventor.Rev",
            "LogPrmtvRev", "TaikoTribRev", "DrumNativRev", "DrumInfiRev", "SpaceZFramey",
            "GobletD2Rev", "HypKanjr_REV", "ScatterDrRev", "PuppyB.Rev", "StompRev",
        ]
        // Real firmware 2.00: instruments are always algo 0 with 79 params;
        // effects use algos 1–9 with these param counts (capture 20260701-213259).
        let effectPrmCounts: [Int16: Int16] = [1: 23, 2: 26, 3: 19, 4: 21, 5: 22, 6: 20, 7: 51, 8: 22, 9: 18]
        var inst = [DSPPatch]()
        var fx = [DSPPatch]()
        func clamped(_ v: Int, to range: ClosedRange<Int>?) -> Int16 {
            guard let range else { return Int16(v) }
            return Int16(min(max(v, range.lowerBound), range.upperBound))
        }
        for i in 0..<DSPProject.patchCount {
            var d = [Int16](repeating: 0, count: DSPPatch.dataCount)
            for j in 0..<79 {
                d[j] = clamped((i * 7 + j * 3) % 128,
                               to: ParameterMap.range(for: .instrument, algoNum: 0, index: j))
            }
            inst.append(DSPPatch(
                algoNum: 0,
                name: instNames[i % instNames.count] + (i < instNames.count ? "" : "\(i)"),
                prmNum: 79,
                data: d))
            let fxAlgo = Int16(i % 9 + 1)
            let fxPrm = effectPrmCounts[fxAlgo]!
            var e = [Int16](repeating: 0, count: DSPPatch.dataCount)
            for j in 0..<Int(fxPrm) {
                e[j] = clamped((i * 5 + j * 11) % 100,
                               to: ParameterMap.range(for: .effect, algoNum: Int(fxAlgo), index: j))
            }
            fx.append(DSPPatch(
                algoNum: fxAlgo,
                name: fxNames[i % fxNames.count] + (i < fxNames.count ? "" : "\(i)"),
                prmNum: fxPrm,
                data: e))
        }
        var memory = [[GroupSlot]]()
        for g in 0..<DSPProject.memoryGroups {
            memory.append((0..<DSPProject.memorySlots).map {
                GroupSlot(inst: (g * 10 + $0) % 80, effect: (g * 10 + $0) % 80)
            })
        }
        // Real device reports InstPatchMax/EffectPatchMax = 79.
        return DSPProject(
            id: 0x2026_0701, name: "MockProject", signature: "AFRAMEKIT-MOCK",
            instPatchMax: 79, effectPatchMax: 79,
            instPatch: inst, effectPatch: fx, memory: memory)
    }

    // MARK: AFrameTransport

    public func open() throws {}
    public func close() {}

    public func write(_ data: Data) throws {
        inBuffer.append(data)
        process()
    }

    public func read(maxLength: Int, timeout: TimeInterval) throws -> Data {
        guard !outBuffer.isEmpty else { throw AFrameTransportError.timeout }
        let n = Swift.min(maxLength, outBuffer.count)
        let out = outBuffer.prefix(n)
        outBuffer.removeFirst(n)
        return Data(out)
    }

    // MARK: Command processing

    private func respond(_ line: String) {
        outBuffer.append(Data((line + "\r\n").utf8))
    }

    private func respondRaw(_ data: Data) {
        outBuffer.append(data)
    }

    private func process() {
        while true {
            if pending != nil {
                guard consumeUploadData() else { return }  // need more bytes
                continue
            }
            guard let nl = inBuffer.firstIndex(of: 0x0A) else { return }
            var line = inBuffer.subdata(in: inBuffer.startIndex..<nl)
            inBuffer.removeSubrange(inBuffer.startIndex...nl)
            if line.last == 0x0D { line.removeLast() }
            handle(String(decoding: line, as: UTF8.self))
        }
    }

    private func handle(_ command: String) {
        let opcode = String(command.prefix(4))
        let argString = command.count > 5 ? String(command.dropFirst(5)) : ""
        let args = argString.isEmpty ? [] : argString.split(separator: ",", omittingEmptySubsequences: false).map(String.init)

        switch opcode {
        // ---- Get ----
        case "aFG0": respond("VER.2.01-BLD.001 2026/07/01 00:00:00 [MOCK]")
        case "aFG1": respond("\(mode.rawValue)")
        case "aFG2": respond("\(switchState)")
        case "aFG3": respond("\(encoder)")
        case "aFG4": respond("\(led)")
        case "aFG5":
            let addr = intArg(args, 0) ?? 0
            let num = intArg(args, 1) ?? 1
            let lo = max(0, min(63, addr))
            let hi = max(lo, min(64, lo + num))
            respond(String(decoding: lcd[lo..<hi], as: UTF8.self))
        case "aFG6": respond("\(project.memoryGrp)")
        case "aFG7": respond("\(project.memoryNum)")
        case "aFG8":
            meterPhase += 1
            let p = meterPhase
            respond("\((p * 3) % 16),\((p * 5) % 16),\((p * 7) % 16),\((p * 7 + 2) % 16)")
        case "aFG9":
            meterPhase += 1
            respond("\((meterPhase * 2) % 16),\((meterPhase * 3) % 16)")
        case "aFGA":
            let g = Int(project.memoryGrp), n = Int(project.memoryNum)
            let slot = project.memory[g][n]
            respond("\(g),\(n),\(project.memoryMax[g]),\(slot.inst),\(slot.effect)")
        case "aFGB":
            respond(String(format: "I%02d:%@", project.instPatchSel, instPatchEdit.name))
            respond(String(format: "E%02d:%@", project.effectPatchSel, effectPatchEdit.name))
        case "aFGC":
            let patch = (intArg(args, 0) ?? 0) == 0 ? instPatchEdit : effectPatchEdit
            respondToneBlock(patch)
        case "aFGD":
            let g = max(0, min(7, intArg(args, 0) ?? 0))
            respond("Gmax:\(project.memoryMax[g])")
            for slot in project.memory[g] { respond("\(slot.inst),\(slot.effect)") }
        case "aFGE":
            let list = (intArg(args, 0) ?? 0) == 0 ? project.instPatch : project.effectPatch
            for p in list { respond(p.name) }
        case "aFGF":
            let list = (intArg(args, 0) ?? 0) == 0 ? project.instPatch : project.effectPatch
            let num = intArg(args, 1) ?? 0
            if num == -1 {
                for p in list { respondToneBlock(p) }
            } else if (0..<list.count).contains(num) {
                respondToneBlock(list[num])
            } else {
                respond("1")
            }

        // ---- Set ----
        case "aFS1":
            let on = (intArg(args, 0) ?? 0) == 1
            if on {
                if mode == .home { mode = .editExt; respond("0") } else { respond("1") }
            } else {
                if mode == .editExt { mode = .home; respond("0") } else { respond("1") }
            }
        case "aFS2": switchState = UInt16(truncatingIfNeeded: intArg(args, 0) ?? 0); respond("0")
        case "aFS3": encoder = Int16(truncatingIfNeeded: intArg(args, 0) ?? 0); respond("0")
        case "aFS4": led = UInt32(truncatingIfNeeded: intArg(args, 0) ?? 0); respond("0")
        case "aFS5":
            let addr = max(0, min(63, intArg(args, 0) ?? 0))
            // Text may itself contain commas; rejoin everything after the addr.
            let text = args.dropFirst().joined(separator: ",")
            for (i, b) in text.utf8.enumerated() where addr + i < 64 {
                lcd[addr + i] = (0x20...0x7E).contains(b) ? b : 0x20
            }
            respond("0")
        case "aFS6", "aFS7":
            guard mode == .home else { respond("1"); return }
            let up = (intArg(args, 0) ?? 0) == 1
            if opcode == "aFS6" {
                project.memoryGrp = Int16((Int(project.memoryGrp) + (up ? 1 : 7)) % 8)
            } else {
                let maxN = Int(project.memoryMax[Int(project.memoryGrp)])
                project.memoryNum = Int16((Int(project.memoryNum) + (up ? 1 : maxN - 1)) % maxN)
            }
            respond("0")

        // ---- External editing ----
        case "aFE0":
            guard requireExtMode() else { return }
            let g = intArg(args, 0) ?? 0, n = intArg(args, 1) ?? 0
            guard (0..<8).contains(g), (0..<40).contains(n) else { respond("1"); return }
            project.memoryGrp = Int16(g)
            project.memoryNum = Int16(n)
            let slot = project.memory[g][n]
            project.instPatchSel = Int16(slot.inst)
            project.effectPatchSel = Int16(slot.effect)
            instPatchEdit = project.instPatch[slot.inst]
            effectPatchEdit = project.effectPatch[slot.effect]
            respond("0")
        case "aFE1":
            guard requireExtMode() else { return }
            let g = intArg(args, 0) ?? 0, n = intArg(args, 1) ?? 0, mx = intArg(args, 2) ?? 10
            guard (0..<8).contains(g), (0..<40).contains(n), (1...40).contains(mx) else { respond("1"); return }
            project.memoryGrp = Int16(g)
            project.memoryNum = Int16(n)
            project.memoryMax[g] = Int16(mx)
            project.memory[g][n] = GroupSlot(inst: Int(project.instPatchSel), effect: Int(project.effectPatchSel))
            respond("0")
        case "aFE2":
            guard requireExtMode() else { return }
            let sel = intArg(args, 0) ?? 0, n = intArg(args, 1) ?? 0
            guard (0..<80).contains(n) else { respond("1"); return }
            if sel == 0 {
                project.instPatchSel = Int16(n)
                instPatchEdit = project.instPatch[n]
            } else {
                project.effectPatchSel = Int16(n)
                effectPatchEdit = project.effectPatch[n]
            }
            respond("0")
        case "aFE3":
            guard requireExtMode() else { return }
            let sel = intArg(args, 0) ?? 0, n = intArg(args, 1) ?? 0, v = intArg(args, 2) ?? 0
            guard (0..<DSPPatch.dataCount).contains(n) else { respond("1"); return }
            // Real firmware rejects out-of-range values with NG
            // (capture 20260702-082114); mirror that.
            let algo = Int(sel == 0 ? instPatchEdit.algoNum : effectPatchEdit.algoNum)
            if let range = ParameterMap.range(for: sel == 0 ? .instrument : .effect,
                                              algoNum: algo, index: n),
               !range.contains(v) {
                respond("1")
                return
            }
            if sel == 0 {
                instPatchEdit.data[n] = Int16(truncatingIfNeeded: v)
            } else {
                effectPatchEdit.data[n] = Int16(truncatingIfNeeded: v)
            }
            respond("0")
        case "aFE4":
            guard requireExtMode() else { return }
            let sel = intArg(args, 0) ?? 0
            let name = args.count > 2 ? args.dropFirst(2).joined(separator: ",") : ""
            if sel == 0 { instPatchEdit.name = String(name.prefix(DSPPatch.nameLength)) }
            else { effectPatchEdit.name = String(name.prefix(DSPPatch.nameLength)) }
            respond("0")
        case "aFE5":
            guard requireExtMode() else { return }
            let sel = intArg(args, 0) ?? 0, n = intArg(args, 1) ?? 0
            guard (0..<80).contains(n) else { respond("1"); return }
            if sel == 0 { project.instPatch[n] = instPatchEdit }
            else { project.effectPatch[n] = effectPatchEdit }
            respond("0")
        case "aFE6":
            guard requireExtMode() else { return }
            let sel = intArg(args, 0) ?? 0
            let bufMode = intArg(args, 1) ?? 0
            let patch = sel == 0 ? instPatchEdit : effectPatchEdit
            if bufMode == 0 {
                let payload = MockAFrame.binaryEditBuffPayload(patch)
                var frame = Data()
                frame.appendLE(UInt16(payload.count))
                frame.append(payload)
                respondRaw(frame)
            } else {  // accept 1 or 2 as TXT until hardware resolves the spec typo
                respondToneBlock(patch)
                respond("\(Checksums.txtToneSum(algoNum: Int(patch.algoNum), values: patch.data.prefix(Int(patch.prmNum)).map(Int.init)))")
            }
        case "aFE7":
            guard requireExtMode() else { return }
            let sel = (intArg(args, 0) ?? 0) == 0 ? ToneSelect.instrument : .effect
            pending = .editBuff(sel)
            respond("0")
        case "aFE8":
            guard requireExtMode() else { return }
            let encoded = AFrameLZ.encode(framed: project.encode())
            var frame = Data()
            frame.appendLE(UInt16(encoded.count))
            frame.append(encoded)
            respondRaw(frame)
        case "aFE9":
            guard requireExtMode() else { return }
            pending = .project
            respond("0")

        default:
            respond("1")
        }
    }

    /// aFE6/aFE7 binary payload: variable length, algo + name[20] + prm_num +
    /// data[prm_num] + byteSum16 (verified against VER.2.00 hardware).
    static func binaryEditBuffPayload(_ patch: DSPPatch) -> Data {
        patch.encodeTransfer()
    }

    private func requireExtMode() -> Bool {
        if mode != .editExt {
            respond("-1")
            return false
        }
        return true
    }

    private func respondToneBlock(_ patch: DSPPatch) {
        respond("\(patch.algoNum)")
        respond(patch.name)
        respond("\(patch.prmNum)")
        // Real firmware terminates the data line with a trailing comma
        // (confirmed in capture session 20260701-212833).
        respond(patch.data.prefix(Int(patch.prmNum)).map(String.init).joined(separator: ",") + ",")
    }

    private func intArg(_ args: [String], _ i: Int) -> Int? {
        guard i < args.count else { return nil }
        return Int(args[i].trimmingCharacters(in: .whitespaces))
    }

    // MARK: Upload data phase (aFE7 / aFE9)

    /// Returns false if more bytes are needed.
    private func consumeUploadData() -> Bool {
        guard let job = pending else { return true }
        guard inBuffer.count >= 2 else { return false }
        let b = [UInt8](inBuffer.prefix(2))
        let size = Int(b[0]) | (Int(b[1]) << 8)
        guard inBuffer.count >= 2 + size else { return false }
        inBuffer.removeFirst(2)
        let payload = Data(inBuffer.prefix(size))
        inBuffer.removeFirst(size)
        pending = nil

        switch job {
        case .editBuff(let sel):
            do {
                let patch = try DSPPatch.decodeTransfer(payload)
                if sel == .instrument { instPatchEdit = patch } else { effectPatchEdit = patch }
                respond("0")
            } catch AFrameError.checksumMismatch {
                respond("3")
            } catch {
                respond("2")
            }
        case .project:
            guard let decoded = try? AFrameLZ.decode(framed: payload),
                  decoded.count == DSPProject.byteSize else { respond("2"); return true }
            guard let proj = try? DSPProject.decode(decoded, verifyChecksum: true) else {
                respond("3")
                return true
            }
            project = proj
            instPatchEdit = proj.instPatch[Int(proj.instPatchSel)]
            effectPatchEdit = proj.effectPatch[Int(proj.effectPatchSel)]
            respond("0")
        }
        return true
    }
}
