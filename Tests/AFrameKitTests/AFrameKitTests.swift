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
