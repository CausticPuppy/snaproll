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
