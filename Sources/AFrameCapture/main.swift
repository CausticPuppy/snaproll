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
}

func parseOptions() -> Options {
    var opts = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--port": opts.port = it.next()
        case "--out": opts.outDir = it.next()
        case "--mock": opts.useMock = true
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
