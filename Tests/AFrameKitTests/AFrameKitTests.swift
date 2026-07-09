import XCTest
@testable import AFrameKit

final class AFrameLZTests: XCTestCase {
    func testRoundTripStructuredData() throws {
        var data = Data()
        for i in 0..<5000 { data.append(UInt8(i % 7 == 0 ? 0 : i % 251)) }
        data.append(Data(repeating: 0x42, count: 2000))  // long runs
        let encoded = AFrameLZ.encode(framed: data)
        XCTAssertEqual(try AFrameLZ.decode(framed: encoded), data)
        XCTAssertLessThan(encoded.count, data.count, "structured data should compress")
    }

    func testRoundTripRandomData() throws {
        var rng = SystemRandomNumberGenerator()
        let data = Data((0..<4096).map { _ in UInt8.random(in: 0...255, using: &rng) })
        XCTAssertEqual(try AFrameLZ.decode(framed: AFrameLZ.encode(framed: data)), data)
    }

    func testRoundTripEscapeByteHeavyData() throws {
        // Exercises the (unverified on hardware) 7D 7D literal stuffing.
        var data = Data(repeating: AFrameLZ.escapeByte, count: 300)
        data.append(Data([0x7C, 0x7D, 0x7E, 0x00, 0x7D]))
        XCTAssertEqual(try AFrameLZ.decode(framed: AFrameLZ.encode(framed: data)), data)
    }

    func testRoundTripFullProjectImage() throws {
        let image = MockAFrame.demoProject().encode()
        XCTAssertEqual(image.count, DSPProject.byteSize)
        XCTAssertEqual(try AFrameLZ.decode(framed: AFrameLZ.encode(framed: image)), image)
    }

    func testDecodeRealDeviceCapture() throws {
        // Byte-exact regression against the VER.2.00 hardware blob, if the
        // capture directory is present.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("captures/20260701-213259/project_lzss.bin")
        guard let blob = try? Data(contentsOf: url) else {
            throw XCTSkip("hardware capture not available")
        }
        let decoded = try AFrameLZ.decode(framed: blob)
        XCTAssertEqual(decoded.count, DSPProject.byteSize)
        let project = try DSPProject.decode(decoded, verifyChecksum: true)
        XCTAssertEqual(project.name, "aFrame Initial Project")
        XCTAssertEqual(project.signature, "ATV Corporation")
        XCTAssertEqual(project.instPatch[0].name, "SnappyFramey")
        XCTAssertEqual(project.instPatch[0].prmNum, 79)
    }

    func testEmptyInput() throws {
        XCTAssertEqual(try AFrameLZ.decode(framed: AFrameLZ.encode(framed: Data())).count, 0)
    }
}

final class ModelCodecTests: XCTestCase {
    func testPatchRoundTrip() throws {
        var data = [Int16](repeating: 0, count: DSPPatch.dataCount)
        for i in 0..<67 { data[i] = Int16(i * 3 - 40) }
        let patch = DSPPatch(algoNum: 3, name: "Harmo Drum", prmNum: 67, data: data)
        let encoded = patch.encode()
        XCTAssertEqual(encoded.count, DSPPatch.byteSize)
        XCTAssertEqual(try DSPPatch.decode(encoded), patch)
    }

    func testProjectRoundTripWithChecksum() throws {
        let project = MockAFrame.demoProject()
        let image = project.encode()
        XCTAssertEqual(image.count, DSPProject.byteSize)
        let decoded = try DSPProject.decode(image, verifyChecksum: true)
        XCTAssertEqual(decoded, project)
    }

    func testProjectChecksumRejectsCorruption() throws {
        var image = MockAFrame.demoProject().encode()
        image[100] ^= 0xFF
        XCTAssertThrowsError(try DSPProject.decode(image, verifyChecksum: true)) { error in
            guard case AFrameError.checksumMismatch = error else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
        }
    }
}

final class ParameterMapTests: XCTestCase {
    func testTableSizesMatchHardware() {
        // prm_num values reported by VER.2.00 firmware (capture 20260701-213259).
        XCTAssertEqual(ParameterMap.instrument.count, 79)
        let expected = [1: 23, 2: 26, 3: 19, 4: 21, 5: 22, 6: 20, 7: 51, 8: 22, 9: 18]
        for (algo, count) in expected {
            XCTAssertEqual(ParameterMap.effects[algo]?.count, count, "algo \(algo)")
        }
        XCTAssertEqual(Set(ParameterMap.effects.keys), Set(ParameterMap.effectAlgoNames.keys))
    }

    func testIndicesAreContiguous() {
        XCTAssertEqual(ParameterMap.instrument.map(\.index), Array(0..<79))
        for (algo, params) in ParameterMap.effects {
            XCTAssertEqual(params.map(\.index), Array(0..<params.count), "algo \(algo)")
        }
    }

    func testRangeTableSizes() {
        XCTAssertEqual(ParameterMap.instrumentRanges.count, 79)
        for (algo, params) in ParameterMap.effects {
            XCTAssertEqual(ParameterMap.effectRanges[algo]?.count, params.count, "algo \(algo)")
        }
    }

    func testRangesMatchSweepCapture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("captures/20260702-082318/param_sweep.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("hardware sweep capture not available")
        }
        var table: [ClosedRange<Int>]?
        var cursor = 0
        var checked = 0
        for line in text.split(separator: "\n") {
            if line.hasPrefix("=== INST") {
                table = ParameterMap.instrumentRanges
                cursor = 0
            } else if line.hasPrefix("=== FX") {
                table = ParameterMap.effectRanges[Int(line.dropFirst(6).prefix(1))!]
                cursor = 0
            } else if line.hasPrefix("--- "), let ranges = table {
                guard let open = line.range(of: "range=["),
                      let close = line.range(of: "]", range: open.upperBound..<line.endIndex)
                else { continue }
                let nums = line[open.upperBound..<close.lowerBound].split(separator: ",").compactMap { Int($0) }
                XCTAssertEqual(ranges[cursor], nums[0]...nums[1], "\(line)")
                cursor += 1
                checked += 1
            }
        }
        XCTAssertEqual(checked, 301)
    }

    func testCodedDisplaysCoverHardwareRanges() {
        // Every enumerated label table must exactly cover the accepted value
        // range the hardware reported; every onOff must be exactly 0...1.
        func check(_ params: [ParameterDescriptor], _ ranges: [ClosedRange<Int>], tag: String) {
            for (p, range) in zip(params, ranges) {
                switch p.display {
                case .enumerated(let labels):
                    XCTAssertEqual(Set(labels.keys), Set(range), "\(tag) \(p.name)")
                case .onOff:
                    XCTAssertEqual(range, 0...1, "\(tag) \(p.name)")
                case .centerEdge:
                    XCTAssertEqual(range, 0...100, "\(tag) \(p.name)")
                default:
                    break
                }
            }
        }
        check(ParameterMap.instrument, ParameterMap.instrumentRanges, tag: "inst")
        for (algo, params) in ParameterMap.effects {
            check(params, ParameterMap.effectRanges[algo]!, tag: "fx\(algo)")
        }
    }

    func testNamesMatchHardwareLCDProbe() throws {
        // Regression against the device's own LCD rendering of every
        // parameter (aframe-capture --probe). Skips if the capture is absent.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("captures/20260702-080734/param_probe.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("hardware probe capture not available")
        }
        // Known firmware LCD typo: Flanger's switch prints "Flnager Sw".
        let lcdAliases = ["Flnager Sw": "Flanger Sw"]

        var current: [ParameterDescriptor]?
        var checked = 0
        for line in text.split(separator: "\n") {
            if line.hasPrefix("=== INST") {
                current = ParameterMap.instrument
            } else if line.hasPrefix("=== FX") {
                let algo = Int(line.dropFirst(6).prefix(1))!
                current = ParameterMap.effects[algo]
            } else if let params = current {
                // "I  4 =     40 | ?Bf:SnappyFramey | MainDcay: 4.0sec"
                let cols = line.split(separator: "|")
                guard cols.count == 3,
                      let idx = Int(cols[0].dropFirst(1).prefix(4).trimmingCharacters(in: .whitespaces))
                else { continue }
                var lcdName = String(cols[2].split(separator: ":").first ?? "")
                    .trimmingCharacters(in: .whitespaces)
                lcdName = lcdAliases[lcdName] ?? lcdName
                XCTAssertEqual(params[idx].name, lcdName, "index \(idx) in \(params[idx].section)")
                checked += 1
            }
        }
        XCTAssertEqual(checked, 79 + 222, "expected every probed parameter to be checked")
    }
}

final class ParameterFormatterTests: XCTestCase {
    func testFormatsMatchHardwareLCDStyle() {
        // Expectations taken from real LCD renderings in the probe captures.
        XCTAssertEqual(ParameterFormatter.string(for: 40, display: .centerEdge), "C60/E40")
        XCTAssertEqual(ParameterFormatter.string(for: 64, display: .pan), "C00")
        XCTAssertEqual(ParameterFormatter.string(for: 49, display: .pan), "L15")
        XCTAssertEqual(ParameterFormatter.string(for: 79, display: .pan), "R15")
        XCTAssertEqual(
            ParameterFormatter.string(for: 40, display: .scaled(divisor: 10, unit: "sec", signed: false)),
            "4.0 sec")
        XCTAssertEqual(
            ParameterFormatter.string(for: 13, display: .scaled(divisor: 100, unit: nil, signed: true)),
            "+0.13")
        XCTAssertEqual(
            ParameterFormatter.string(for: -15, display: .scaled(divisor: 10, unit: "dB", signed: true)),
            "-1.5 dB")
        XCTAssertEqual(
            ParameterFormatter.string(for: 356, display: .levelWithMode(modes: ["--", "P+", "P-"])),
            "100 P+")
        XCTAssertEqual(
            ParameterFormatter.string(for: 80, display: .levelWithMode(modes: ["M+", "M-"])),
            "80 M+")
        XCTAssertEqual(ParameterFormatter.string(for: 4200, display: .bpmSyncTime), "420.0 ms")
        XCTAssertEqual(ParameterFormatter.string(for: -512, display: .bpmSyncTime), "♩8")
        XCTAssertEqual(ParameterFormatter.string(for: -2032, display: .bpmSyncTime), "♩T16 +240")
        XCTAssertEqual(
            ParameterFormatter.string(for: 20, display: .enumerated(ParameterMap.compRatioNames)),
            "INF:1")
        // Mute sensitivity (inst idx 10/22/35): OFF/ON(n)/+offset/negative,
        // matching captures/20260702-082318 MainMute renderings.
        XCTAssertEqual(ParameterFormatter.string(for: 0, display: .muteSensitivity), "OFF")
        XCTAssertEqual(ParameterFormatter.string(for: 65, display: .muteSensitivity), "+64")
        XCTAssertEqual(ParameterFormatter.string(for: -90, display: .muteSensitivity), "-90")
        XCTAssertEqual(
            ParameterFormatter.string(for: 1, display: .muteSensitivity,
                                      context: .init(globalMuteSens: 30)), "ON(30)")
        // Without the sibling Mute Sens in context, "ON" renders bare.
        XCTAssertEqual(ParameterFormatter.string(for: 1, display: .muteSensitivity), "ON")
        // Tune: Hz zone verbatim; note zone as note/cents (idx 3/15/28),
        // matching captures/20260708-204307/tune_probe.txt.
        XCTAssertEqual(ParameterFormatter.string(for: 440, display: .tune), "440Hz")
        XCTAssertEqual(ParameterFormatter.string(for: 12544, display: .tune), "12544Hz")
        XCTAssertEqual(ParameterFormatter.string(for: -1150, display: .tune), "C0/-50")
        XCTAssertEqual(ParameterFormatter.string(for: -1200, display: .tune), "C0/+00")
        XCTAssertEqual(ParameterFormatter.string(for: -1250, display: .tune), "C#0/-50")
        XCTAssertEqual(ParameterFormatter.string(for: -6900, display: .tune), "A4/+00")
        XCTAssertEqual(ParameterFormatter.string(for: -12749, display: .tune), "G9/+49")
        // SC (inst idx 9/21/77): OFF, or scale + one of 13 modes packed as
        // mode×256 + scale, matching captures/20260708-210922/sc_probe.txt.
        XCTAssertEqual(ParameterFormatter.string(for: 0, display: .scaleControl), "OFF")
        XCTAssertEqual(ParameterFormatter.string(for: 5, display: .scaleControl),
                       "MScale \u{00B7} Pressure \u{2191}")     // mode 0
        XCTAssertEqual(ParameterFormatter.string(for: 261, display: .scaleControl),
                       "MScale \u{00B7} Pressure \u{2193}")     // mode 1
        XCTAssertEqual(ParameterFormatter.string(for: 3101, display: .scaleControl),
                       "Chrmtic \u{00B7} Skip \u{21C5}")        // mode 12, scale 29
        // Pan (inst idx 50/51/52): L/R position + one of 12 pressure-pan modes
        // packed as mode×256 + position, matching
        // captures/20260708-213318/pan_probe.txt.
        XCTAssertEqual(ParameterFormatter.string(for: 64, display: .panWithMode), "C00")   // Off, center
        XCTAssertEqual(ParameterFormatter.string(for: 1, display: .panWithMode), "L63")    // Off, hard left
        XCTAssertEqual(ParameterFormatter.string(for: 320, display: .panWithMode),
                       "C00 \u{00B7} Pressure +127")            // mode 1
        XCTAssertEqual(ParameterFormatter.string(for: 2880, display: .panWithMode),
                       "C00 \u{00B7} Pitch Hi\u{2192}L")        // mode 11
    }

    func testTuneValueEncodingAndConversion() {
        // Raw round-trips through the structured representation.
        for raw in [16, 440, 12544, -1150, -1200, -1250, -6900, -12700, -12749] {
            XCTAssertEqual(TuneValue(raw: raw).raw, raw, "raw round trip \(raw)")
        }
        XCTAssertEqual(TuneValue(raw: -6900), .note(midi: 69, cents: 0))   // A4
        XCTAssertEqual(TuneValue(raw: -1150), .note(midi: 12, cents: -50)) // C0/-50
        // Pitch-preserving Hz<->note conversion (A4 = 440 Hz).
        XCTAssertEqual(TuneMap.hz(forMidi: 69, cents: 0), 440)
        XCTAssertEqual(TuneMap.nearestNote(forHz: 440).midi, 69)
        XCTAssertEqual(TuneMap.nearestNote(forHz: 440).cents, 0)
        // Conversions stay inside the valid bands.
        XCTAssertTrue(TuneMap.hzRange.contains(TuneMap.hz(forMidi: 12, cents: -50)))
        XCTAssertTrue(TuneMap.hzRange.contains(TuneMap.hz(forMidi: 127, cents: 49)))
    }

    func testTuneMatchesHardwareProbe() throws {
        // Regression against the device's own LCD rendering of swept Tune values.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("captures/20260708-204307/tune_probe.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("hardware tune probe capture not available")
        }
        var checked = 0
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: "|")
            guard cols.count == 2,
                  let raw = Int(cols[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let device = cols[1].trimmingCharacters(in: .whitespaces)
            if device == "(rejected)" { continue }           // the two-band gap / out-of-range
            let label = String(device.split(separator: ":").last ?? "")  // strip "MainTune:"
                .replacingOccurrences(of: " ", with: "")     // drop the LCD's column padding
            XCTAssertEqual(ParameterFormatter.string(for: raw, display: .tune), label, "raw \(raw)")
            // Every accepted value round-trips through parse.
            XCTAssertEqual(ParameterFormatter.parse(label, display: .tune), raw, "parse \(label)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 30, "expected both MainTune and Sub Tune sweeps")
    }

    func testSCValueEncoding() {
        XCTAssertEqual(SCValue(raw: 0), .off)
        XCTAssertEqual(SCValue(raw: 5), .scale(code: 5, mode: 0))
        XCTAssertEqual(SCValue(raw: 261), .scale(code: 5, mode: 1))     // +256
        XCTAssertEqual(SCValue(raw: 3101), .scale(code: 29, mode: 12))  // max
        // Raw round-trips through the structured representation.
        for raw in [0, 1, 5, 29, 261, 517, 1285, 2309, 3101] {
            XCTAssertEqual(SCValue(raw: raw).raw, raw, "raw round trip \(raw)")
        }
        // Off-grid values (device-tolerated, meaningless) collapse to OFF.
        XCTAssertEqual(SCValue(raw: 133), .off)   // scale part 133 > 29
        XCTAssertEqual(SCValue(raw: -251), .off)  // negative headroom
        XCTAssertEqual(SCValue(raw: 256), .off)   // scale part 0
        // The 13 modes group as the manual lists them (Pressure/Random/Seq/Skip).
        XCTAssertEqual(ScaleControlMap.modeNames.count, 13)
    }

    func testSCMatchesHardwareProbe() throws {
        // Regression against the device's own LCD rendering of swept SC values.
        // The mode glyphs are arrow chars the LCD reader can't decode, so this
        // asserts the scale field (the composite's low byte + the scale table).
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("captures/20260708-210922/sc_probe.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("hardware SC probe capture not available")
        }
        var inScaleAxis = false
        var checked = 0
        for line in text.split(separator: "\n") {
            if line.hasPrefix("-- scale axis") { inScaleAxis = true; continue }
            if line.hasPrefix("-- mode axis") { inScaleAxis = false; continue }
            guard inScaleAxis else { continue }
            let cols = line.split(separator: "|")
            guard cols.count == 2,
                  let raw = Int(cols[0].trimmingCharacters(in: .whitespaces)),
                  (0...29).contains(raw) else { continue }        // skip the small-negative aliases
            // The LCD packs a 7-char scale field right after "XxxxSC:".
            let lcd = String(cols[1])
            guard let colon = lcd.range(of: "SC:") else { continue }
            let field = String(lcd[colon.upperBound...].prefix(7))
                .trimmingCharacters(in: .whitespaces)
            let expected = raw == 0 ? "OFF" : ScaleControlMap.scaleName(raw)
            XCTAssertEqual(field, expected, "raw \(raw)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 50, "expected MainSC and XtraSC scale sweeps")
    }

    func testPanValueEncoding() {
        XCTAssertEqual(PanValue(raw: 64), PanValue(position: 64, mode: 0))     // C00, Off
        XCTAssertEqual(PanValue(raw: 320), PanValue(position: 64, mode: 1))    // +256
        XCTAssertEqual(PanValue(raw: 2943), PanValue(position: 127, mode: 11)) // max
        for raw in [1, 64, 127, 320, 1344, 1856, 2880, 2943] {
            XCTAssertEqual(PanValue(raw: raw).raw, raw, "raw round trip \(raw)")
        }
        // The 12 modes decompose to 5 categories and recompose losslessly.
        XCTAssertEqual(PanMap.categories.count, 5)
        var seen = Set<Int>()
        for mode in PanMap.modeRange {
            let (ci, vi) = PanMap.decompose(mode: mode)
            XCTAssertEqual(PanMap.compose(category: ci, variant: vi), mode, "mode \(mode)")
            seen.insert(mode)
        }
        XCTAssertEqual(seen.count, 12)
        // "Off" is category 0 with no variant; composing it ignores the variant.
        XCTAssertEqual(PanMap.compose(category: 0, variant: 3), 0)
    }

    func testPanMatchesHardwareProbe() throws {
        // Regression against the device's own LCD rendering. Some mode codes are
        // arrow/± glyphs the LCD reader can't decode, so this asserts the
        // position field (rendered identically to the LCD's L/C/R notation).
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("captures/20260708-213318/pan_probe.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("hardware pan probe capture not available")
        }
        var inPositionAxis = false
        var checked = 0
        for line in text.split(separator: "\n") {
            if line.hasPrefix("-- position axis") { inPositionAxis = true; continue }
            if line.hasPrefix("-- mode axis") { inPositionAxis = false; continue }
            if line.hasPrefix("===") { inPositionAxis = false; continue }
            guard inPositionAxis else { continue }
            let cols = line.split(separator: "|")
            guard cols.count == 2,
                  let raw = Int(cols[0].trimmingCharacters(in: .whitespaces)) else { continue }
            // The LCD packs a 3-char position field right after "Mix…Pan:".
            let lcd = String(cols[1])
            guard let colon = lcd.range(of: "Pan:") else { continue }
            let field = String(lcd[colon.upperBound...].prefix(3))
            XCTAssertEqual(field, PanMap.positionString(raw), "raw \(raw)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 8, "expected MixMainPan and MixDryCPan position sweeps")
    }

    func testParseInvertsFormatting() {
        // Round-trips: parsing the formatted string recovers the raw value.
        let cases: [(Int, ParameterDisplay)] = [
            (12345, .raw(unit: nil)),
            (-9000, .signed(unit: nil)),
            (120, .raw(unit: "BPM")),
            (-15, .scaled(divisor: 10, unit: "dB", signed: true)),
            (13, .scaled(divisor: 100, unit: nil, signed: true)),
            (49, .pan),
            (79, .pan),
            (64, .pan),
            (40, .centerEdge),
            (4200, .bpmSyncTime),
            (0, .muteSensitivity),   // "OFF"
            (1, .muteSensitivity),   // "ON" (no context)
            (2, .muteSensitivity),   // "+1"
            (101, .muteSensitivity), // "+100"
            (-90, .muteSensitivity), // "-90"
        ]
        for (value, display) in cases {
            let text = ParameterFormatter.string(for: value, display: display)
            XCTAssertEqual(ParameterFormatter.parse(text, display: display), value,
                           "round trip failed for \(text)")
        }
        // The contextful "ON(n)" form parses back to 1, and "OFF" to 0.
        XCTAssertEqual(ParameterFormatter.parse("ON(30)", display: .muteSensitivity), 1)
        XCTAssertEqual(ParameterFormatter.parse("OFF", display: .muteSensitivity), 0)
        // Tune parses both zones and tolerates spacing / case / omitted slash.
        for (value, display) in [(16, ParameterDisplay.tune), (12544, .tune),
                                 (-1150, .tune), (-1250, .tune), (-6900, .tune), (-12749, .tune)] {
            let text = ParameterFormatter.string(for: value, display: display)
            XCTAssertEqual(ParameterFormatter.parse(text, display: display), value,
                           "tune round trip failed for \(text)")
        }
        XCTAssertEqual(ParameterFormatter.parse("440 Hz", display: .tune), 440)
        XCTAssertEqual(ParameterFormatter.parse("a4", display: .tune), -6900)      // note, no cents
        XCTAssertEqual(ParameterFormatter.parse("C#0/-50", display: .tune), -1250)
        // levelWithMode parses only the level portion (mode is the popup's).
        XCTAssertEqual(ParameterFormatter.parse("100 P+", display: .levelWithMode(modes: ["--", "P+", "P-"])), 100)
        // Bare-number tolerance and rejection of junk.
        XCTAssertEqual(ParameterFormatter.parse("-2048", display: .raw(unit: nil)), -2048)
        XCTAssertNil(ParameterFormatter.parse("nope", display: .raw(unit: nil)))
        XCTAssertNil(ParameterFormatter.parse("", display: .signed(unit: nil)))
        // Controls with their own value don't accept typed input.
        XCTAssertNil(ParameterFormatter.parse("On", display: .onOff))
        XCTAssertNil(ParameterFormatter.parse("MScale \u{00B7} Pressure \u{2191}", display: .scaleControl))
        XCTAssertNil(ParameterFormatter.parse("C00 \u{00B7} Pressure +127", display: .panWithMode))
    }

    func testUnitSplitsFromValueText() {
        // Fixed units render as a separate label; the field holds only the value.
        XCTAssertEqual(ParameterFormatter.unit(for: .raw(unit: "Hz")), "Hz")
        XCTAssertEqual(ParameterFormatter.valueText(for: 123, display: .raw(unit: "Hz")), "123")
        XCTAssertEqual(
            ParameterFormatter.valueText(for: -15, display: .scaled(divisor: 10, unit: "dB", signed: true)),
            "-1.5")
        // Unitless and context-unit types keep everything in the field.
        XCTAssertNil(ParameterFormatter.unit(for: .raw(unit: nil)))
        XCTAssertNil(ParameterFormatter.unit(for: .bpmSyncTime))
        XCTAssertEqual(ParameterFormatter.valueText(for: 64, display: .pan), "C00")
        XCTAssertEqual(ParameterFormatter.valueText(for: 4200, display: .bpmSyncTime), "420.0 ms")
        // The field text (unit stripped) still parses back to the raw value.
        let display = ParameterDisplay.raw(unit: "Hz")
        let field = ParameterFormatter.valueText(for: 123, display: display)
        XCTAssertEqual(ParameterFormatter.parse(field, display: display), 123)
    }
}

final class MockRangeValidationTests: XCTestCase {
    func testMockRejectsOutOfRangeLikeFirmware() throws {
        let client = AFrameClient(transport: MockAFrame())
        client.responseTimeout = 0.2
        try client.setExtMode(true)
        // Main In (idx 0) has hardware range 0...100.
        try client.extChangeEditBuffParam(.instrument, index: 0, value: 100)
        XCTAssertThrowsError(
            try client.extChangeEditBuffParam(.instrument, index: 0, value: 101))
        // Demo project values must all be range-valid.
        let (tone, _) = try client.extGetEditBuffText(.instrument)
        for (i, v) in tone.values.enumerated() {
            if let r = ParameterMap.range(for: .instrument, algoNum: 0, index: i) {
                XCTAssertTrue(r.contains(v), "idx \(i) value \(v) outside \(r)")
            }
        }
    }
}

final class ClientAgainstMockTests: XCTestCase {
    var mock: MockAFrame!
    var client: AFrameClient!

    override func setUp() {
        super.setUp()
        mock = MockAFrame()
        client = AFrameClient(transport: mock)
        client.responseTimeout = 0.2
        client.bulkTimeout = 1.0
    }

    func testVersionAndMode() throws {
        XCTAssertTrue(try client.getVersion().hasPrefix("VER."))
        XCTAssertEqual(try client.getMode(), .home)
    }

    func testExtModeGating() throws {
        // Ext commands must be refused outside MODE_EDIT_EXT.
        XCTAssertThrowsError(try client.extSelectGroup(group: 0, num: 0)) { error in
            XCTAssertEqual(error as? AFrameError, .notInExtEditMode)
        }
        try client.setExtMode(true)
        XCTAssertEqual(try client.getMode(), .editExt)
        try client.extSelectGroup(group: 0, num: 0)
        try client.setExtMode(false)
        XCTAssertEqual(try client.getMode(), .home)
    }

    func testMeterReads() throws {
        // aFG8 → 4 input/output peaks, aFG9 → pressure pitch/mute. Values are
        // small non-negative steps; the mock animates them across calls.
        let peak = try client.getPeakLevel()
        for v in [peak.inCenter, peak.inEdge, peak.outL, peak.outR] {
            XCTAssertTrue((0...15).contains(v), "peak \(v) out of 0...15")
        }
        let pressure = try client.getPressure()
        XCTAssertGreaterThanOrEqual(pressure.pitch, 0)
        XCTAssertGreaterThanOrEqual(pressure.mute, 0)
        // Successive reads advance (the mock's phase changes), proving the poll
        // loop would see live movement.
        let peak2 = try client.getPeakLevel()
        XCTAssertNotEqual(PeakLevels(inCenter: peak.inCenter, inEdge: peak.inEdge,
                                     outL: peak.outL, outR: peak.outR),
                          peak2)
    }

    func testPanelStateRoundTrip() throws {
        try client.setLCD(addr: 0, text: "HELLO AFRAME")
        XCTAssertEqual(try client.getLCD(addr: 0, count: 12), "HELLO AFRAME")
        try client.setLED(0x0000_0003)
        XCTAssertEqual(try client.getLED(), 3)
        try client.setEncoder(-123)
        XCTAssertEqual(try client.getEncoder(), -123)
    }

    func testParameterEditFlow() throws {
        try client.setExtMode(true)
        try client.extChangeToneNum(.instrument, num: 5)
        try client.extChangeEditBuffParam(.instrument, index: 3, value: 99)
        try client.extChangeEditBuffName(.instrument, name: "My Tone")

        let (tone, _) = try client.extGetEditBuffText(.instrument)
        XCTAssertEqual(tone.values[3], 99)
        XCTAssertEqual(tone.name, "My Tone")

        // Write to project slot 7 and read back through the project list.
        try client.extWriteEditBuffToProject(.instrument, num: 7)
        let names = try client.getProjectToneNameList(.instrument)
        XCTAssertEqual(names[7], "My Tone")
        let data = try client.getProjectToneData(.instrument, num: 7)
        XCTAssertEqual(data.values[3], 99)
    }

    func testGroupWriteFlow() throws {
        try client.setExtMode(true)
        try client.extChangeToneNum(.instrument, num: 42)
        try client.extChangeToneNum(.effect, num: 17)
        try client.extWriteGroup(group: 2, num: 4, max: 12)

        let list = try client.getProjectGroupList(group: 2)
        XCTAssertEqual(list.max, 12)
        XCTAssertEqual(list.slots[4], GroupSlot(inst: 42, effect: 17))

        let info = try client.getCurrentGroupToneNum()
        XCTAssertEqual(info.group, 2)
        XCTAssertEqual(info.number, 4)
    }

    func testEditBuffBinaryRoundTrip() throws {
        try client.setExtMode(true)
        // 79-param instrument: 2 + 20 + 2 + 158 + 2 bytes (matches hardware).
        let payload = try client.extGetEditBuffBinary(.instrument)
        XCTAssertEqual(payload.count, 184)

        var patch = try client.extGetEditBuff(.instrument)
        patch.data[0] = 77
        patch.name = "RoundTrip"
        try client.extSetEditBuff(.instrument, patch: patch)
        let reread = try client.extGetEditBuff(.instrument)
        XCTAssertEqual(reread.name, "RoundTrip")
        XCTAssertEqual(reread.data[0], 77)
        XCTAssertEqual(reread.prmNum, 79)
    }

    func testProjectDownloadUploadRoundTrip() throws {
        try client.setExtMode(true)
        var project = try client.extGetProject()
        XCTAssertEqual(project.name, "MockProject")
        XCTAssertEqual(project.instPatch.count, 80)

        project.name = "Edited"
        project.instPatch[0].name = "NewTone"
        try client.extSetProject(project)

        let reread = try client.extGetProject()
        XCTAssertEqual(reread.name, "Edited")
        XCTAssertEqual(reread.instPatch[0].name, "NewTone")
    }

    func testRandomizerBlend() {
        let range = 0...100
        // Rate 0 leaves the value untouched; rate 1 jumps to the target.
        XCTAssertEqual(Randomizer.blend(current: 40, randomTarget: 90, rate: 0, range: range), 40)
        XCTAssertEqual(Randomizer.blend(current: 40, randomTarget: 90, rate: 1, range: range), 90)
        // Partial rate interpolates and rounds.
        XCTAssertEqual(Randomizer.blend(current: 40, randomTarget: 80, rate: 0.5, range: range), 60)
        // Result is always clamped to the range, and rate is clamped to 0...1.
        XCTAssertEqual(Randomizer.blend(current: 10, randomTarget: 999, rate: 1, range: range), 100)
        XCTAssertEqual(Randomizer.blend(current: 50, randomTarget: 0, rate: 2, range: 20...80), 20)
        // A fully random draw within range stays in range across many samples.
        for _ in 0..<200 {
            let v = Randomizer.blend(current: 5, randomTarget: Int.random(in: range), rate: 1, range: range)
            XCTAssertTrue(range.contains(v))
        }
    }

    func testGroupRecallStoreAndMax() throws {
        try client.setExtMode(true)

        // Recall loads the slot's inst+effect as the current selection.
        let before = try client.getProjectGroupList(group: 1)
        try client.extSelectGroup(group: 1, num: 2)
        let info = try client.getCurrentGroupToneNum()
        XCTAssertEqual(info.group, 1)
        XCTAssertEqual(info.number, 2)
        XCTAssertEqual(info.instNum, before.slots[2].inst)
        XCTAssertEqual(info.effectNum, before.slots[2].effect)

        // Select specific tones, then store into a slot while setting MAX.
        try client.extChangeToneNum(.instrument, num: 7)
        try client.extChangeToneNum(.effect, num: 9)
        try client.extWriteGroup(group: 1, num: 3, max: 12)
        let after = try client.getProjectGroupList(group: 1)
        XCTAssertEqual(after.max, 12)
        XCTAssertEqual(after.slots[3], GroupSlot(inst: 7, effect: 9))
        // Storing one slot must not disturb its neighbors.
        XCTAssertEqual(after.slots[2], before.slots[2])
    }

    func testProjectFileFormatIsDecodedImage() throws {
        // The `.prj` file the load/save UI reads and writes is the decoded
        // 0x7F00 image (identical to legacy aFrameEdit's format). Verify our
        // codec accepts such a raw image directly and re-encodes byte-exact,
        // using the committed device-decoded capture if present.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("captures/20260701-213259/project_decoded.bin")
        guard let image = try? Data(contentsOf: url) else {
            throw XCTSkip("hardware capture not available")
        }
        XCTAssertEqual(image.count, DSPProject.byteSize)  // 0x7F00 = 32512
        let project = try DSPProject.decode(image, verifyChecksum: true)
        XCTAssertEqual(project.signature, "ATV Corporation")
        // A load re-compresses the exact file bytes; that must survive the
        // device's LZSS round trip byte-for-byte.
        XCTAssertEqual(try AFrameLZ.decode(framed: AFrameLZ.encode(framed: image)), image)
    }

    func testCSVParsingMatchesRealFirmwareFormat() throws {
        // Real firmware ends data lines with a trailing comma (capture
        // 20260701-212833); spec's TXT example shows interior empties.
        XCTAssertEqual(try AFrameClient.parseCSVInts("40,3,-12,0,"), [40, 3, -12, 0])
        XCTAssertEqual(try AFrameClient.parseCSVInts("50,0,,,64,"), [50, 0, 0, 0, 64])
        XCTAssertEqual(try AFrameClient.parseCSVInts("7"), [7])
        XCTAssertThrowsError(try AFrameClient.parseCSVInts("12,abc,3"))
    }

    func testToneDataListMatchesNames() throws {
        let tones = try client.getProjectToneDataList(.instrument)
        let names = try client.getProjectToneNameList(.instrument)
        XCTAssertEqual(tones.count, 80)
        XCTAssertEqual(tones.map(\.name), names)
    }
}

final class RandomizationRulesTests: XCTestCase {
    private func inst(_ name: String) -> ParameterDescriptor {
        ParameterMap.instrument.first { $0.name == name }!
    }
    private func fx(_ algo: Int, _ name: String) -> ParameterDescriptor {
        ParameterMap.effects[algo]!.first { $0.name == name }!
    }

    func testInstrumentTimbreLayersRandomizeExceptFixedParams() {
        // '***' timbre params change.
        for name in ["MainOvt", "MainHrmNo.", "MainTune", "MainDcay", "MainSC",
                     "Sub Delay", "XtraType", "XtraJxModLev"] {
            XCTAssertTrue(RandomizationRules.isRandomizable(inst(name), domain: .instrument),
                          "\(name) should randomize")
        }
        // '(Fix)' timbre params do not.
        for name in ["Main In", "Sub In", "Xtra In", "MainMute", "Sub Mute",
                     "XtraMute", "Main OD", "Sub OD", "XtraJxCarLev"] {
            XCTAssertFalse(RandomizationRules.isRandomizable(inst(name), domain: .instrument),
                           "\(name) is fixed and must not randomize")
        }
    }

    func testInstrumentNonTimbreSectionsAreExcluded() {
        // Dry / Pressure / Mixer / Master are never randomized.
        for name in ["DryC.EqF", "Edge HPF", "Mute Sens", "Bend Curve",
                     "MixMainLev", "MixMainPan", "MixMasterLev", "MixMasterBal"] {
            XCTAssertFalse(RandomizationRules.isRandomizable(inst(name), domain: .instrument),
                           "\(name) is outside the timbre layers and must not randomize")
        }
        XCTAssertEqual(RandomizationRules.randomizableSections(in: ParameterMap.instrument,
                                                               domain: .instrument),
                       ["Main", "Sub", "Xtra"])
    }

    func testEffectFixedAndExcludedParams() {
        // Reverb: '***' change, '(Fix)'/'---' do not.
        for name in ["Time", "Pre Delay", "ER Dens", "HF Damp", "ER Level", "Rev Level"] {
            XCTAssertTrue(RandomizationRules.isRandomizable(fx(1, name), domain: .effect), name)
        }
        for name in ["Pan Spread", "Wet Level", "Dry Level", "Reverb Sw", "FxMtrx",
                     "PressMode", "PressSens", "PressAtck", "PressRele"] {
            XCTAssertFalse(RandomizationRules.isRandomizable(fx(1, name), domain: .effect), name)
        }
        // SpaceR headphone monitor + fixed delay levels are excluded.
        XCTAssertFalse(RandomizationRules.isRandomizable(fx(8, "Phones"), domain: .effect))
        XCTAssertFalse(RandomizationRules.isRandomizable(fx(8, "DlyWetLev"), domain: .effect))
        XCTAssertTrue(RandomizationRules.isRandomizable(fx(8, "Azimuth"), domain: .effect))
    }

    func testAmbienceAndCompressionSectionsExcluded() {
        for name in ["AmbienceType", "Ambience Lev", "Comp Sw", "CompThrs",
                     "CompRatio", "CompGain"] {
            XCTAssertFalse(RandomizationRules.isRandomizable(fx(2, name), domain: .effect),
                           "\(name) (ambience/comp) must not randomize")
        }
    }

    func testBpmSyncedDelayTimesDoNotChange() {
        let timeL = fx(2, "Time L")  // .bpmSyncTime
        // Positive value = a real time in ms: randomizes.
        XCTAssertTrue(RandomizationRules.shouldRandomize(timeL, currentValue: 250, domain: .effect))
        // Non-positive = tempo-synced ("BPM") display: stays put.
        XCTAssertFalse(RandomizationRules.shouldRandomize(timeL, currentValue: -300, domain: .effect))
        XCTAssertFalse(RandomizationRules.shouldRandomize(timeL, currentValue: 0, domain: .effect))
    }
}
