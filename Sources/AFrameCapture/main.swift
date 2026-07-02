import Foundation
import AFrameKit

// aframe-capture — one-session data harvester for the ATV aFrame.
//
// Connects over the serial port and dumps everything needed to close the
// documentation gaps in the API spec: firmware version, all tone names,
// all tone data (TXT), edit-buffer dumps in BIN and TXT modes (probing the
// spec's "0:BIN 2:TXT" vs "mode1" ambiguity), and the raw LZSS project blob.
//
// Usage:
//   aframe-capture                          # list candidate ports
//   aframe-capture --port /dev/cu.XXXX      # run capture to ./captures/<timestamp>
//   aframe-capture --port /dev/cu.XXXX --out DIR
//   aframe-capture --mock                   # dry-run against the mock device

struct Options {
    var port: String?
    var outDir: String?
    var useMock = false
    var probe = false
    var sweep = false
    var sweepQuick = false
}

func parseOptions() -> Options {
    var opts = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--port": opts.port = it.next()
        case "--out": opts.outDir = it.next()
        case "--mock": opts.useMock = true
        case "--probe": opts.probe = true
        case "--sweep": opts.sweep = true
        case "--sweep-quick": opts.sweepQuick = true
        default:
            FileHandle.standardError.write(Data("Unknown option: \(arg)\n".utf8))
            exit(2)
        }
    }
    return opts
}

let opts = parseOptions()

guard opts.useMock || opts.port != nil else {
    print("No --port given. Candidate serial ports:")
    let ports = SerialPortDiscovery.candidatePorts()
    if ports.isEmpty { print("  (none found)") }
    for p in ports { print("  \(p)") }
    print("\nRun: aframe-capture --port <path>   (or --mock for a dry run)")
    exit(0)
}

// --- Session setup ------------------------------------------------------

let stamp: String = {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: Date())
}()
let outDir = URL(fileURLWithPath: opts.outDir ?? "captures/\(stamp)", isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var logLines = [String]()
func log(_ s: String) {
    print(s)
    logLines.append(s)
}
func save(_ name: String, _ data: Data) {
    let url = outDir.appendingPathComponent(name)
    try? data.write(to: url)
    log("  saved \(name) (\(data.count) bytes)")
}
func save(_ name: String, _ text: String) {
    save(name, Data(text.utf8))
}

let transport: AFrameTransport = opts.useMock
    ? MockAFrame()
    : POSIXSerialPort(path: opts.port!)
let client = AFrameClient(transport: transport)

func step(_ title: String, _ body: () throws -> Void) {
    log("== \(title)")
    do {
        try body()
    } catch {
        log("  FAILED: \(error.localizedDescription)")
        // Resynchronize: a failure mid-response leaves the rest of the
        // device's output unread, which would corrupt every later step.
        client.drain()
        log("  (drained stale bytes to resync)")
    }
}

// --- Capture sequence ----------------------------------------------------

log("aframe-capture session \(stamp)")
log("target: \(opts.useMock ? "MOCK DEVICE" : opts.port!)")
log("output: \(outDir.path)\n")

do {
    try transport.open()
} catch {
    log("Cannot open port: \(error.localizedDescription)")
    exit(1)
}

var extModeEntered = false

// Discard anything the device may still be streaming from a previous session.
client.drain()

// --- Parameter LCD probe mode -------------------------------------------
//
// For every parameter index, rewrite its *current* value with lcd=1 so the
// device renders that parameter on its own display, then read the LCD back.
// This makes the hardware itself enumerate the index -> name/format mapping.
// Edit-buffer only; the project is never written. Selections are restored.

func runParamProbe() throws {
    var report = [String]()

    func probe(_ sel: ToneSelect, tag: String) throws {
        let (tone, _) = try client.extGetEditBuffText(sel)
        let header = "=== \(tag) algo=\(tone.algoNum) prm_num=\(tone.values.count) tone=\(tone.name)"
        log(header)
        report.append(header)
        for idx in 0..<tone.values.count {
            try client.extChangeEditBuffParam(sel, index: idx, value: tone.values[idx], lcd: true)
            usleep(60_000)  // allow the LCD to repaint
            let l1 = try client.getLCD(addr: 0, count: 16)
            let l2 = try client.getLCD(addr: 32, count: 16)
            let line = String(format: "%@ %2d = %6d | %@ | %@", tag.prefix(1) as CVarArg, idx, tone.values[idx], l1, l2)
            log("  " + line)
            report.append(line)
        }
    }

    let info = try client.getCurrentGroupToneNum()

    step("Probe instrument parameters (algo 0)") {
        try probe(.instrument, tag: "INST")
    }

    step("Probe effect parameters (algos 1-9)") {
        // Pick one project tone per effect algorithm.
        let tones = try client.getProjectToneDataList(.effect)
        var algoTone = [Int: Int]()
        for (num, t) in tones.enumerated() where algoTone[t.algoNum] == nil {
            algoTone[t.algoNum] = num
        }
        log("  algorithm coverage: \(algoTone.keys.sorted())")
        for (algo, num) in algoTone.sorted(by: { $0.key < $1.key }) {
            try client.extChangeToneNum(.effect, num: num, lcd: false)
            try probe(.effect, tag: "FX\(algo)")
        }
    }

    step("Restore selections") {
        try client.extSelectGroup(group: info.group, num: info.number, lcd: true)
    }

    save("param_probe.txt", report.joined(separator: "\n") + "\n")
}

// --- Value-sweep probe mode ----------------------------------------------
//
// Extends the LCD probe: writes a *series* of values per parameter and reads
// the LCD label for each, to enumerate coded-value tables (Ovt, SC, PressMode,
// CompRatio, …), clamped display ranges (via ±32767), and the MIX BUS switch
// encoding in the mixer Lev/Snd values. Edit-buffer only; every parameter is
// restored to its original value right after its sweep.

func runValueSweep() throws {
    var report = [String]()

    // Candidate sets
    let enumValues = Array(-2...30) + [40, 50, 64, 100, 127]
    let mixValues = [-356, -256, -228, -128, -100, -64, -1, 0, 1, 63, 64,
                     100, 127, 128, 192, 228, 256, 356]

    // Coded parameters to fully enumerate: [index: values]
    let instSweeps: [Int: [Int]] = [
        1: enumValues, 9: enumValues, 10: enumValues,      // MainOvt, MainSC, MainMute
        13: enumValues, 21: enumValues, 22: enumValues,    // Sub Ovt, Sub SC, Sub Mute
        27: enumValues, 35: enumValues,                    // XtraType, XtraMute
        49: enumValues, 70: enumValues, 77: enumValues,    // Bend Curve, JxF.Type, XtraSC
        55: mixValues, 60: mixValues,                      // MixMainLev, MixMainSnd (bus switch)
    ]
    let fxSweeps: [Int: [Int: [Int]]] = [
        1: [10: enumValues, 15: enumValues, 18: enumValues, 19: enumValues],  // PressMode, FxMtrx, CompRatio, CompKnee
        2: [0: enumValues, 17: enumValues],                                   // Delay Type, AmbienceType
        3: [0: enumValues],                                                   // Chorus Type
        6: [0: enumValues],                                                   // Wah Type
        8: [1: enumValues],                                                   // AutoRevo
    ]

    /// The firmware validates aFE3 values and answers NG for out-of-range
    /// ones (discovered 20260702-082114), so ranges are found by accept/reject.
    func trySet(_ sel: ToneSelect, _ idx: Int, _ v: Int, lcd: Bool = false) throws -> Bool {
        do {
            try client.extChangeEditBuffParam(sel, index: idx, value: v, lcd: lcd)
            return true
        } catch AFrameError.commandRejected {
            return false
        }
    }

    /// Largest (dir=+1) or smallest (dir=-1) accepted value, by binary search
    /// from a known-accepted anchor. Assumes the valid range is contiguous.
    func findBound(_ sel: ToneSelect, _ idx: Int, anchor: Int, dir: Int) throws -> Int {
        let limit = dir > 0 ? 32767 : -32768
        if try trySet(sel, idx, limit) { return limit }
        var good = anchor
        var bad = limit
        while abs(bad - good) > 1 {
            let mid = good + (bad - good) / 2
            if try trySet(sel, idx, mid) { good = mid } else { bad = mid }
        }
        return good
    }

    func sweep(_ sel: ToneSelect, algo: Int, overrides: [Int: [Int]], quick: Bool = false) throws {
        let (tone, _) = try client.extGetEditBuffText(sel)
        let tag = sel == .instrument ? "INST" : "FX\(algo)"
        report.append("=== \(tag) tone=\(tone.name)")
        log("== sweeping \(tag) (\(quick ? overrides.count : tone.values.count) params)")
        let params = ParameterMap.parameters(for: sel, algoNum: algo)
        let indices = quick ? overrides.keys.sorted() : Array(0..<tone.values.count)
        for idx in indices {
            guard idx < tone.values.count else { continue }
            let orig = Int(tone.values[idx])
            let name = params.map { $0[idx].name } ?? "?"
            if quick {
                report.append("--- \(tag) idx \(idx) \(name) orig=\(orig)")
            } else {
                let minV = try findBound(sel, idx, anchor: orig, dir: -1)
                let maxV = try findBound(sel, idx, anchor: orig, dir: +1)
                report.append("--- \(tag) idx \(idx) \(name) range=[\(minV),\(maxV)] orig=\(orig)")
            }
            if let values = overrides[idx] {
                var lastLCD = ""
                for v in values {
                    guard try trySet(sel, idx, v, lcd: true) else { continue }
                    usleep(50_000)
                    let lcd = try client.getLCD(addr: 32, count: 16)
                    if lcd != lastLCD {  // record first value of each distinct rendering
                        report.append(String(format: "%8d | %@", v, lcd))
                        lastLCD = lcd
                    }
                }
            }
            _ = try trySet(sel, idx, orig)
        }
    }

    // Follow-up targets: PressMode labels vary per algorithm, and delay-time
    // parameters have a negative BPM-sync zone (e.g. Time L range [-2032,10000]).
    let negTimes = Array(-16...(-1)) + [-20, -24, -32, -48, -64, -96, -128,
                                        -256, -512, -1024, -2032]
    let quickFxSweeps: [Int: [Int: [Int]]] = [
        2: [1: negTimes, 11: enumValues],   // Delay: Time L BPM zone, PressMode
        4: [6: enumValues],                 // Flanger: PressMode
        5: [7: enumValues],                 // Phaser: PressMode
        7: [0: negTimes, 36: enumValues],   // M.Tap: Time 1 BPM zone, PressMode
        8: [4: negTimes, 8: enumValues],    // SpaceR: DlyTime BPM zone, PressMode
        9: [2: negTimes],                   // SpaceZ: DTime L BPM zone
    ]

    let quick = opts.sweepQuick
    let info = try client.getCurrentGroupToneNum()

    if !quick {
        step("Sweep instrument parameters") {
            try sweep(.instrument, algo: 0, overrides: instSweeps)
        }
    }

    step("Sweep effect parameters (algos 1-9)") {
        let tones = try client.getProjectToneDataList(.effect)
        var algoTone = [Int: Int]()
        for (num, t) in tones.enumerated() where algoTone[t.algoNum] == nil {
            algoTone[t.algoNum] = num
        }
        let sweeps = quick ? quickFxSweeps : fxSweeps
        for (algo, num) in algoTone.sorted(by: { $0.key < $1.key }) {
            guard !quick || sweeps[algo] != nil else { continue }
            try client.extChangeToneNum(.effect, num: num, lcd: false)
            try sweep(.effect, algo: algo, overrides: sweeps[algo] ?? [:], quick: quick)
        }
    }

    step("Restore selections") {
        try client.extSelectGroup(group: info.group, num: info.number, lcd: true)
    }

    save("param_sweep.txt", report.joined(separator: "\n") + "\n")
}

if opts.probe || opts.sweep || opts.sweepQuick {
    step("GetVersion") {
        log("  \(try client.getVersion())")
    }
    step("Enter external edit mode") {
        try client.setExtMode(true)
        guard try client.getMode() == .editExt else {
            throw AFrameError.notInExtEditMode
        }
    }
    do {
        if opts.probe { try runParamProbe() }
        if opts.sweep || opts.sweepQuick { try runValueSweep() }
    } catch {
        log("PROBE FAILED: \(error.localizedDescription)")
        client.drain()
    }
    step("Leave external edit mode") {
        try client.setExtMode(false)
    }
    save("session.log", logLines.joined(separator: "\n") + "\n")
    transport.close()
    log("\nDone. Probe results in \(outDir.path)")
    exit(0)
}

step("GetVersion (aFG0)") {
    let v = try client.getVersion()
    log("  version: \(v)")
    save("version.txt", v + "\n")
}

step("GetMode (aFG1)") {
    let m = try client.getMode()
    log("  mode: \(m) (\(m.rawValue))")
    if m != .home {
        log("  NOTE: device not in HOME mode; results may differ")
    }
}

step("Panel state (aFG2/3/4, aFG5)") {
    let sw = try client.getSwitch()
    let enc = try client.getEncoder()
    let led = try client.getLED()
    let lcd1 = try client.getLCD(addr: 0, count: 16)
    let lcd2 = try client.getLCD(addr: 32, count: 16)
    let text = "switch=0x\(String(sw, radix: 16))\nencoder=\(enc)\nled=0x\(String(led, radix: 16))\nlcd1=[\(lcd1)]\nlcd2=[\(lcd2)]\n"
    log(text.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))
    save("panel_state.txt", text)
}

step("Current group/tone (aFGA, aFGB)") {
    let info = try client.getCurrentGroupToneNum()
    let names = try client.getCurrentToneName()
    let text = "group=\(info.group) number=\(info.number) max=\(info.max) inst=\(info.instNum) effect=\(info.effectNum)\n\(names.inst)\n\(names.effect)\n"
    log("  \(text.replacingOccurrences(of: "\n", with: " | "))")
    save("current_selection.txt", text)
}

step("Tone name lists (aFGE)") {
    let inst = try client.getProjectToneNameList(.instrument)
    let fx = try client.getProjectToneNameList(.effect)
    save("tone_names_inst.txt", inst.joined(separator: "\n") + "\n")
    save("tone_names_effect.txt", fx.joined(separator: "\n") + "\n")
}

step("Full project tone data as text (aFGF:-1) — parameter dictionary source") {
    for (sel, name) in [(ToneSelect.instrument, "inst"), (.effect, "effect")] {
        do {
            let lines = try client.getProjectToneDataListVerbatim(sel)
            save("tone_data_\(name)_verbatim.txt", lines.joined(separator: "\n") + "\n")
            let algoCounts = stride(from: 0, to: lines.count, by: 4)
                .map { "algo=\(lines[$0]) prm_num=\(lines[$0 + 2])" }
            log("  \(name): \(Set(algoCounts).sorted().joined(separator: " | "))")
        } catch {
            log("  bulk \(name) dump failed (\(error.localizedDescription)); falling back to per-tone")
            client.drain()
            var text = ""
            for num in 0..<80 {
                do {
                    let t = try client.getProjectToneData(sel, num: num)
                    text += "#\(num) algo=\(t.algoNum) prm_num=\(t.values.count) name=\(t.name)\n"
                    text += t.values.map(String.init).joined(separator: ",") + "\n"
                } catch {
                    text += "#\(num) FAILED: \(error.localizedDescription)\n"
                    client.drain()
                }
            }
            save("tone_data_\(name)_pertone.txt", text)
        }
    }
}

step("Enter external edit mode (aFS1:1)") {
    try client.setExtMode(true)
    let m = try client.getMode()
    log("  mode now: \(m)")
    extModeEntered = (m == .editExt)
    if !extModeEntered {
        log("  NOTE: device did not report EDIT_EXT; skipping aFE steps")
    }
}

if extModeEntered {
    step("Edit buffer TXT dump — probing mode value 2 vs 1 (aFE6)") {
        for candidate in [2, 1] {
            client.txtModeValue = candidate
            do {
                let (tone, checksumLine) = try client.extGetEditBuffText(.instrument)
                log("  TXT works with mode=\(candidate): algo=\(tone.algoNum) name=\(tone.name) prm_num=\(tone.values.count) checksum=\(checksumLine)")
                save("editbuff_inst_txt_mode\(candidate).txt",
                     "algo=\(tone.algoNum)\nname=\(tone.name)\nvalues=\(tone.values.map(String.init).joined(separator: ","))\nchecksum_line=\(checksumLine)\n")
                let (fxTone, fxSum) = try client.extGetEditBuffText(.effect)
                save("editbuff_effect_txt_mode\(candidate).txt",
                     "algo=\(fxTone.algoNum)\nname=\(fxTone.name)\nvalues=\(fxTone.values.map(String.init).joined(separator: ","))\nchecksum_line=\(fxSum)\n")
                break
            } catch {
                log("  mode=\(candidate) failed: \(error.localizedDescription)")
                client.drain()
            }
        }
    }

    step("Edit buffer BIN dump (aFE6 mode 0) — checksum + layout evidence") {
        let inst = try client.extGetEditBuffBinary(.instrument)
        save("editbuff_inst.bin", inst)
        let fx = try client.extGetEditBuffBinary(.effect)
        save("editbuff_effect.bin", fx)
    }

    step("Project blob (aFE8) — decode and verify") {
        let raw = try client.extGetProjectRaw(waitMs: 10)
        save("project_lzss.bin", raw)
        let decoded = try AFrameLZ.decode(framed: raw)
        save("project_decoded.bin", decoded)
        let project = try DSPProject.decode(decoded, verifyChecksum: true)
        log("  decoded \(decoded.count) bytes; checksum OK")
        log("  project: id=0x\(String(UInt32(bitPattern: project.id), radix: 16)) name=\"\(project.name)\" sig=\"\(project.signature)\"")
        log("  re-encode round trip matches: \(try AFrameLZ.decode(framed: AFrameLZ.encode(framed: decoded)) == decoded)")
    }

    step("Leave external edit mode (aFS1:0)") {
        try client.setExtMode(false)
    }
}

save("session.log", logLines.joined(separator: "\n") + "\n")
transport.close()
log("\nDone. Captures in \(outDir.path)")
