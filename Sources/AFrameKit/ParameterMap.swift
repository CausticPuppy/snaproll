import Foundation

/// How a raw parameter value (Int16 in DSP_PATCH.Data[]) is rendered.
///
/// Derived from the hardware's own LCD rendering, enumerated by the
/// `aframe-capture --probe` / `--sweep` LCD probes against VER.2.00 firmware
/// (captures/20260702-080734, -082318, -083220): every parameter was
/// rewritten with lcd=1 and the display read back; coded parameters were
/// swept across their whole accepted range.
public enum ParameterDisplay: Equatable {
    /// Plain integer, optional unit suffix ("Hz", "ms", "rpm", "deg").
    case raw(unit: String?)
    /// Integer with explicit sign ("+8", "-12"), optional unit.
    case signed(unit: String?)
    /// value / divisor with fixed decimals ("4.0sec" from 40, "+0.13" from 13).
    case scaled(divisor: Int, unit: String?, signed: Bool)
    /// 0–127 panorama; 64 = "C00", below = "L63".."L01", above = "R01".."R63".
    case pan
    /// Center/Edge input split: value v renders "C(100-v)/E(v)".
    case centerEdge
    /// 0 = OFF, 1 = ON.
    case onOff
    /// Coded value; labels are complete over the parameter's valid range.
    case enumerated([Int: String])
    /// Mixer level/send: value = level(0–127) + 256 × mode index.
    /// (The 128–255 zone is accepted by aFE3 but renders garbage — avoid.)
    case levelWithMode(modes: [String])
    /// Delay-time parameter: positive = 0.1 ms units; negative = BPM sync,
    /// encoded -(code × 256 + fine) where code renders a note division
    /// (observed 0="4", 1=".8", 2="8", 4="16", 7="T16") and fine is 0–255.
    case bpmSyncTime
    /// Instrument Main/Sub/Xtra tuning (`TuneValue`). Positive raw = absolute
    /// frequency in Hz (16...12544); negative raw = note mode, encoded
    /// -(MIDI note × 100 + cents) with note 12 (C0) ... 127 (G9) and cents
    /// -50...+49. The two bands are disjoint — raw 1...15 and -1...-1149 are
    /// rejected. Hardware-confirmed: captures/20260708-204307/tune_probe.txt.
    case tune
    /// Instrument Main/Sub/Xtra mute sensitivity. The hardware renders `0` as
    /// "OFF", `1` as "ON(n)" where n is the tone's global Mute Sens (idx 46,
    /// supplied via the formatter `Context`), `v ≥ 2` as "+(v-1)", and `v < 0`
    /// verbatim. Range -100...101. (LCD-confirmed: captures/20260702-082318,
    /// idx 10/22/35.)
    case muteSensitivity
    /// Instrument Main/Sub/Xtra "scale control by pressure" (`SCValue`). Packs a
    /// musical scale and a scale-control mode as `mode × 256 + scale`, scale
    /// 1...29 (0 = OFF) and mode 0...12. Hardware-confirmed:
    /// captures/20260708-210922/sc_probe.txt.
    case scaleControl
    /// Instrument Main/Sub/Xtra mixer pan (`PanValue`). Packs an L/R position
    /// and a pressure-pan mode as `mode × 256 + position`, position 1...127
    /// (64 = C00) and mode 0...11 (12 modes). Hardware-confirmed:
    /// captures/20260708-213318/pan_probe.txt. (The Dry pans carry no mode and
    /// use plain `.pan`.)
    case panWithMode
    /// Known formatting that is not yet fully modeled (documented in `note`).
    case custom(note: String)
}

public struct ParameterDescriptor: Equatable {
    public let index: Int
    /// Canonical name as the hardware LCD prints it (trimmed).
    public let name: String
    /// UI grouping: Main/Sub/Xtra/Dry/Pressure/Mixer/Master for instruments,
    /// or the algorithm's section for effects.
    public let section: String
    public let display: ParameterDisplay

    public init(_ index: Int, _ name: String, _ section: String, _ display: ParameterDisplay) {
        self.index = index
        self.name = name
        self.section = section
        self.display = display
    }
}

/// The index → parameter mapping for firmware 2.00, confirmed on hardware.
public enum ParameterMap {

    // MARK: Effect algorithm identity (probe-confirmed; note Chorus/Flanger
    // are swapped relative to the block diagram's listing order)

    public static let effectAlgoNames: [Int: String] = [
        1: "Reverb",
        2: "Delay",
        3: "Chorus",
        4: "Flanger",
        5: "Phaser",
        6: "Wah",
        7: "Multi-Tap Delay",
        8: "SpaceR",
        9: "SpaceZ",
    ]

    // MARK: Coded-value tables (complete, from the hardware sweep)

    /// Overtone structure types (MainOvt / Sub Ovt), codes 0–30.
    public static let overtoneNames = [
        "Natural", "Odd No.", "PrimeNo.", "BesselM0", "BesselM1", "BesselM2",
        "BesselM3", "BesselM4", "BesselM5", "BesselM6", "BesselM7", "Membran",
        "MembrnH1", "MembrnH2", "MembrnH3", "MembrnH4", "Taiko", "KettleD",
        "BassDrm", "Tom", "T.Head", "B.Head", "T+B Head", "FryPan", "Cymbal",
        "VibeLow", "VibeMid", "VibeHigh", "Glocken", "Marimba", "Organ",
    ]

    /// Xtra oscillator types, codes 0–19.
    public static let xtraTypeNames = [
        "WhiteNz", "LPF Nz", "HPF Nz", "BPF Nz", "Jingle1", "Jingle2",
        "Jingle3", "Click1", "Click2", "Click3", "Click4", "Jx TxT", "Jx RxR",
        "Jx SxS", "Jx TxR", "Jx TxS", "Jx RxT", "Jx RxS", "Jx SxT", "Jx SxR",
    ]

    /// Pitch-pressure scale types (SC), magnitude codes 1–29 (0 = OFF).
    /// The stored value is a composite `mode × 256 + scale` (see `SCValue`);
    /// this table names the low `scale` part.
    public static let scaleNames = [
        1: "MTriad", 2: "mTriad", 3: "MPenta", 4: "mPenta", 5: "MScale",
        6: "mScale", 7: "Sus", 8: "mHarmo", 9: "mMelo", 10: "mBlues",
        11: "WholeT.", 12: "Altered", 13: "Lydian", 14: "Dorian", 15: "Phrygi.",
        16: "Mxlydi.", 17: "Arabic", 18: "MHungar", 19: "mHungar", 20: "Hindu",
        21: "Ryukyu", 22: "Minnyou", 23: "Miyako", 24: "Ritsu1", 25: "Ritsu2",
        26: "Ryo", 27: "5th", 28: "Octave", 29: "Chrmtic",
    ]

    /// Compressor ratio codes 1–20.
    public static let compRatioNames: [Int: String] = [
        1: "1.1:1", 2: "1.2:1", 3: "1.3:1", 4: "1.4:1", 5: "1.5:1",
        6: "1.6:1", 7: "1.7:1", 8: "1.8:1", 9: "1.9:1", 10: "2:1",
        11: "3:1", 12: "4:1", 13: "5:1", 14: "6:1", 15: "7:1",
        16: "8:1", 17: "9:1", 18: "10:1", 19: "20:1", 20: "INF:1",
    ]

    /// Numeric compression ratios for the `compRatioNames` codes (the ":1"
    /// denominator dropped; INF:1 → `.infinity`). Used to plot the comp curve.
    public static let compRatioValues: [Int: Double] = [
        1: 1.1, 2: 1.2, 3: 1.3, 4: 1.4, 5: 1.5, 6: 1.6, 7: 1.7, 8: 1.8, 9: 1.9,
        10: 2, 11: 3, 12: 4, 13: 5, 14: 6, 15: 7, 16: 8, 17: 9, 18: 10, 19: 20,
        20: .infinity,
    ]

    // MARK: Shared display shorthands

    private static let dB10 = ParameterDisplay.scaled(divisor: 10, unit: "dB", signed: true)
    private static let ms = ParameterDisplay.raw(unit: "ms")
    private static let ms10 = ParameterDisplay.scaled(divisor: 10, unit: "ms", signed: false)
    private static let hz = ParameterDisplay.raw(unit: "Hz")
    private static let plain = ParameterDisplay.raw(unit: nil)
    private static let sgn = ParameterDisplay.signed(unit: nil)

    private static let overtone = ParameterDisplay.enumerated(
        Dictionary(uniqueKeysWithValues: overtoneNames.enumerated().map { ($0, $1) }))
    private static let xtraType = ParameterDisplay.enumerated(
        Dictionary(uniqueKeysWithValues: xtraTypeNames.enumerated().map { ($0, $1) }))
    private static let scale = ParameterDisplay.scaleControl
    private static let muteMode = ParameterDisplay.muteSensitivity

    /// Instrument parameter index of the global "Mute Sens" value that the
    /// Main/Sub/Xtra mute readouts fold into their "ON(n)" rendering.
    public static let muteSensIndex = 46
    private static let bendCurve = ParameterDisplay.enumerated(
        [0: "A0", 1: "A1", 2: "A2", 3: "A3", 4: "A4", 5: "A5", 6: "A6", 7: "A7", 8: "A8"])
    private static let jxFilterType = ParameterDisplay.enumerated([0: "LPF", 1: "HPF", 2: "BPF"])
    private static let mixPan = ParameterDisplay.panWithMode

    private static let pressModeStd = ParameterDisplay.enumerated(
        [0: "OFF", 1: "MUTE", 2: "LEVEL", 3: "SEND", 4: "SPREAD"])
    private static let pressModeDelay = ParameterDisplay.enumerated(
        [0: "OFF", 1: "MUTE", 2: "LEVEL", 3: "SEND", 4: "SPREAD", 5: "TIME++", 6: "TIME--"])
    private static let pressModeModFx = ParameterDisplay.enumerated(
        [0: "OFF", 1: "DEPTH", 2: "MANU++", 3: "MANU--", 4: "RATE++", 5: "RATE--"])
    private static let pressModeSpaceR = ParameterDisplay.enumerated(
        [0: "OFF", 1: "Turn R", 2: "Turn L", 3: "Revo++", 4: "Revo--"])

    private static let fxMtrx = ParameterDisplay.enumerated([0: "Snd/Rtn", 1: "MasterIns"])
    private static let ambienceType = ParameterDisplay.enumerated(
        [0: "OFF", 1: "A", 2: "B", 3: "C", 4: "D", 5: "E"])
    private static let compKnee = ParameterDisplay.enumerated([0: "HARD", 1: "SOFT1", 2: "SOFT2"])
    private static let compRatio = ParameterDisplay.enumerated(compRatioNames)

    /// The compressor block appended to every effect algorithm (firmware 2.0).
    private static func compBlock(from index: Int, section: String) -> [ParameterDescriptor] {
        [
            .init(index, "Comp Sw", section, .onOff),
            .init(index + 1, "CompThrs", section, dB10),
            .init(index + 2, "CompRatio", section, compRatio),
            .init(index + 3, "CompKnee", section, compKnee),
            .init(index + 4, "CompAtck", section, ms10),
            .init(index + 5, "CompRele", section, ms),
            .init(index + 6, "CompGain", section, dB10),
        ]
    }

    private static func pressBlock(from index: Int, section: String,
                                   mode: ParameterDisplay) -> [ParameterDescriptor] {
        [
            .init(index, "PressMode", section, mode),
            .init(index + 1, "PressSens", section, plain),
            .init(index + 2, "PressAtck", section, ms),
            .init(index + 3, "PressRele", section, ms),
        ]
    }

    // MARK: Instrument (algo 0, 79 parameters)

    public static let instrument: [ParameterDescriptor] = [
        // Main timbre
        .init(0, "Main In", "Main", .centerEdge),
        .init(1, "MainOvt", "Main", overtone),
        .init(2, "MainHrmNo.", "Main", plain),
        .init(3, "MainTune", "Main", .tune),
        .init(4, "MainDcay", "Main", .scaled(divisor: 10, unit: "sec", signed: false)),
        .init(5, "Main HFD", "Main", .scaled(divisor: 100, unit: nil, signed: true)),
        .init(6, "Main DQM", "Main", plain),
        .init(7, "Main DFM", "Main", sgn),
        .init(8, "Main PFM", "Main", sgn),
        .init(9, "MainSC", "Main", scale),
        .init(10, "MainMute", "Main", muteMode),
        .init(11, "Main OD", "Main", sgn),
        // Sub timbre
        .init(12, "Sub In", "Sub", .centerEdge),
        .init(13, "Sub Ovt", "Sub", overtone),
        .init(14, "Sub HrmNo.", "Sub", plain),
        .init(15, "Sub Tune", "Sub", .tune),
        .init(16, "Sub Dcay", "Sub", ms),
        .init(17, "Sub HFD", "Sub", .scaled(divisor: 100, unit: nil, signed: true)),
        .init(18, "Sub DQM", "Sub", plain),
        .init(19, "Sub DFM", "Sub", sgn),
        .init(20, "Sub PFM", "Sub", sgn),
        .init(21, "Sub SC", "Sub", scale),
        .init(22, "Sub Mute", "Sub", muteMode),
        .init(23, "Sub OD", "Sub", sgn),
        .init(24, "Sub Delay", "Sub", ms),
        .init(25, "Sub D.Tap", "Sub", plain),
        // Xtra timbre (core)
        .init(26, "Xtra In", "Xtra", .centerEdge),
        .init(27, "XtraType", "Xtra", xtraType),
        .init(28, "XtraTune", "Xtra", .tune),
        .init(29, "XtraDcay", "Xtra", ms),
        .init(30, "XtraHold", "Xtra", ms),
        .init(31, "XtraFltQ", "Xtra", .scaled(divisor: 10, unit: nil, signed: false)),
        .init(32, "Xtra DQM", "Xtra", plain),
        .init(33, "Xtra DFM", "Xtra", sgn),
        .init(34, "Xtra PFM", "Xtra", sgn),
        .init(35, "XtraMute", "Xtra", muteMode),
        .init(36, "XtraDelay", "Xtra", ms),
        .init(37, "XtraD.Tap", "Xtra", sgn),
        // Dry timbre
        .init(38, "DryC.EqF", "Dry", hz),
        .init(39, "DryC.EqG", "Dry", dB10),
        .init(40, "DryC.EqQ", "Dry", .scaled(divisor: 10, unit: nil, signed: false)),
        .init(41, "DryE.EqF", "Dry", hz),
        .init(42, "DryE.EqG", "Dry", dB10),
        .init(43, "DryE.EqQ", "Dry", .scaled(divisor: 10, unit: nil, signed: false)),
        .init(44, "CentrLPF", "Dry", hz),
        .init(45, "Edge HPF", "Dry", hz),
        // Pressure
        .init(46, "Mute Sens", "Pressure", plain),
        .init(47, "Mute Mask", "Pressure", ms),
        .init(48, "Mute Dcay", "Pressure", plain),
        .init(49, "Bend Curve", "Pressure", bendCurve),
        // Mixer
        .init(50, "MixMainPan", "Mixer", mixPan),
        .init(51, "MixSub Pan", "Mixer", mixPan),
        .init(52, "MixXtraPan", "Mixer", mixPan),
        .init(53, "MixDryCPan", "Mixer", .pan),   // Dry pans are position-only
        .init(54, "MixDryEPan", "Mixer", .pan),
        .init(55, "MixMainLev", "Mixer", .levelWithMode(modes: ["--", "P+", "P-"])),
        .init(56, "MixSub Lev", "Mixer", .levelWithMode(modes: ["--", "P+", "P-"])),
        .init(57, "MixXtraLev", "Mixer", .levelWithMode(modes: ["--", "P+", "P-"])),
        .init(58, "MixDryCLev", "Mixer", .levelWithMode(modes: ["--", "P+", "P-"])),
        .init(59, "MixDryELev", "Mixer", .levelWithMode(modes: ["--", "P+", "P-"])),
        .init(60, "MixMainSnd", "Mixer", .levelWithMode(modes: ["M+", "M-"])),
        .init(61, "MixSub Snd", "Mixer", .levelWithMode(modes: ["M+", "M-"])),
        .init(62, "MixXtraSnd", "Mixer", .levelWithMode(modes: ["M+", "M-"])),
        .init(63, "MixDryCSnd", "Mixer", .levelWithMode(modes: ["M+", "M-"])),
        .init(64, "MixDryESnd", "Mixer", .levelWithMode(modes: ["M+", "M-"])),
        // Master
        .init(65, "MixMasterLev", "Master", plain),
        .init(66, "MixMasterBal", "Master", .pan),
        // Xtra timbre (extended: delay envelope + JingleX + scale/boost)
        .init(67, "XtraD.Fluct", "Xtra", plain),
        .init(68, "XtraD.Atck", "Xtra", ms),
        .init(69, "XtraD.Dcay", "Xtra", ms),
        .init(70, "XtraJxF.Type", "Xtra", jxFilterType),
        .init(71, "XtraJxFR", "Xtra", .custom(note: "negative = ratio × -100 (\"1.00\" from -100); positive = Hz")),
        .init(72, "XtraJxMR", "Xtra", .custom(note: "see XtraJxFR")),
        .init(73, "XtraJxXFMod", "Xtra", sgn),
        .init(74, "XtraJxCarLev", "Xtra", plain),
        .init(75, "XtraJxModLev", "Xtra", plain),
        .init(76, "XtraJxRingLv", "Xtra", plain),
        .init(77, "XtraSC", "Xtra", scale),
        .init(78, "XtraBoost", "Xtra", plain),
    ]

    // MARK: Effects (algos 1–9)

    public static let effects: [Int: [ParameterDescriptor]] = [
        1: reverb, 2: delay, 3: chorus, 4: flanger, 5: phaser,
        6: wah, 7: multiTapDelay, 8: spaceR, 9: spaceZ,
    ]

    static let reverb: [ParameterDescriptor] = [
        .init(0, "Time", "Reverb", .scaled(divisor: 10, unit: "sec", signed: false)),
        .init(1, "Pre Delay", "Reverb", ms),
        .init(2, "ER Dens", "Reverb", plain),
        .init(3, "Rev Dens", "Reverb", plain),
        .init(4, "HF Damp", "Reverb", .scaled(divisor: 100, unit: nil, signed: false)),
        .init(5, "Pan Spread", "Reverb", plain),
        .init(6, "ER Level", "Reverb", plain),
        .init(7, "Rev Level", "Reverb", plain),
        .init(8, "Wet Level", "Reverb", plain),
        .init(9, "Dry Level", "Reverb", plain),
    ] + pressBlock(from: 10, section: "Reverb", mode: pressModeStd) + [
        .init(14, "Reverb Sw", "Reverb", .onOff),
        .init(15, "FxMtrx", "Reverb", fxMtrx),
    ] + compBlock(from: 16, section: "Comp")

    static let delay: [ParameterDescriptor] = [
        .init(0, "Type", "Delay", .enumerated(
            [0: "Stereo In", 1: "Mono In", 2: "Panning LR", 3: "Panning RL"])),
        .init(1, "Time L", "Delay", .bpmSyncTime),
        .init(2, "Time R", "Delay", .bpmSyncTime),
        .init(3, "Feedback", "Delay", plain),
        .init(4, "HF Damp", "Delay", .scaled(divisor: 100, unit: nil, signed: false)),
        .init(5, "Pan Spread", "Delay", plain),
        .init(6, "Wet Level", "Delay", plain),
        .init(7, "Dry Level", "Delay", plain),
        .init(8, "Mod Rate", "Delay", .scaled(divisor: 10, unit: "Hz", signed: false)),
        .init(9, "Mod Depth", "Delay", plain),
        .init(10, "Mod Phase", "Delay", .raw(unit: "deg")),
    ] + pressBlock(from: 11, section: "Delay", mode: pressModeDelay) + [
        .init(15, "Delay Sw", "Delay", .onOff),
        .init(16, "FxMtrx", "Delay", fxMtrx),
        .init(17, "AmbienceType", "Ambience", ambienceType),
        .init(18, "Ambience Lev", "Ambience", plain),
    ] + compBlock(from: 19, section: "Comp")

    static let chorus: [ParameterDescriptor] = [
        .init(0, "Type", "Chorus", .enumerated(
            [0: "2PHASE NORM", 1: "2PHASE XMIX", 2: "3PHASE NORM",
             3: "3PHASE XMIX", 4: "6PHASE NORM", 5: "6PHASE XMIX"])),
        .init(1, "Mod Rate", "Chorus", .scaled(divisor: 10, unit: "Hz", signed: false)),
        .init(2, "Mod Depth", "Chorus", plain),
        .init(3, "Mod Phase", "Chorus", .raw(unit: "deg")),
        .init(4, "Wet HPF", "Chorus", hz),
        .init(5, "Wet LPF", "Chorus", hz),
        .init(6, "Wet Level", "Chorus", plain),
        .init(7, "Dry Level", "Chorus", plain),
        .init(8, "Chorus Sw", "Chorus", .onOff),
        .init(9, "FxMtrx", "Chorus", fxMtrx),
        .init(10, "AmbienceType", "Ambience", ambienceType),
        .init(11, "Ambience Lev", "Ambience", plain),
    ] + compBlock(from: 12, section: "Comp")

    static let flanger: [ParameterDescriptor] = [
        .init(0, "RATE", "Flanger", plain),
        .init(1, "DEPTH", "Flanger", plain),
        .init(2, "MANUAL", "Flanger", plain),
        .init(3, "RESO", "Flanger", plain),
        .init(4, "XFB", "Flanger", plain),
        .init(5, "MOD PH", "Flanger", .raw(unit: "deg")),
    ] + pressBlock(from: 6, section: "Flanger", mode: pressModeModFx) + [
        .init(10, "Flanger Sw", "Flanger", .onOff),  // LCD prints "Flnager Sw" (firmware typo)
        .init(11, "FxMtrx", "Flanger", fxMtrx),
        .init(12, "AmbienceType", "Ambience", ambienceType),
        .init(13, "Ambience Lev", "Ambience", plain),
    ] + compBlock(from: 14, section: "Comp")

    static let phaser: [ParameterDescriptor] = [
        .init(0, "RATE", "Phaser", plain),
        .init(1, "DEPTH", "Phaser", plain),
        .init(2, "MANUAL", "Phaser", plain),
        .init(3, "RESO", "Phaser", plain),
        .init(4, "XFB", "Phaser", plain),
        .init(5, "MOD_PH", "Phaser", .raw(unit: "deg")),
        .init(6, "STAGE", "Phaser", plain),
    ] + pressBlock(from: 7, section: "Phaser", mode: pressModeModFx) + [
        .init(11, "Phaser Sw", "Phaser", .onOff),
        .init(12, "FxMtrx", "Phaser", fxMtrx),
        .init(13, "AmbienceType", "Ambience", ambienceType),
        .init(14, "Ambience Lev", "Ambience", plain),
    ] + compBlock(from: 15, section: "Comp")

    static let wah: [ParameterDescriptor] = [
        .init(0, "Type", "Wah", .enumerated(
            [0: "CRYBABY", 1: "BPF", 2: "LPF", 3: "HPF", 4: "PEAKING"])),
        .init(1, "Manual Freq", "Wah", plain),
        .init(2, "Freq Min", "Wah", hz),
        .init(3, "Freq Max", "Wah", hz),
        .init(4, "Filter Q", "Wah", .scaled(divisor: 10, unit: nil, signed: false)),
        .init(5, "PressSw", "Wah", .onOff),
        .init(6, "PressSens", "Wah", plain),
        .init(7, "PressAtck", "Wah", ms),
        .init(8, "PressRele", "Wah", ms),
        .init(9, "Wah Sw", "Wah", .onOff),
        .init(10, "FxMtrx", "Wah", fxMtrx),
        .init(11, "AmbienceType", "Ambience", ambienceType),
        .init(12, "Ambience Lev", "Ambience", plain),
    ] + compBlock(from: 13, section: "Comp")

    static let multiTapDelay: [ParameterDescriptor] = {
        var params = (0..<10).map {
            ParameterDescriptor($0, "Time \($0 + 1)", "Taps", .bpmSyncTime)
        }
        params.append(.init(10, "Time FB", "Taps", .bpmSyncTime))
        params += (11..<21).map {
            ParameterDescriptor($0, "Lev \($0 - 10)", "Taps", plain)
        }
        params += (21..<31).map {
            ParameterDescriptor($0, "Pan \($0 - 20)", "Taps", .pan)
        }
        params += [
            .init(31, "Feedback", "M.Tap Delay", plain),
            .init(32, "HF Damp", "M.Tap Delay", .scaled(divisor: 100, unit: nil, signed: false)),
            .init(33, "Pan Spread", "M.Tap Delay", plain),
            .init(34, "Wet Level", "M.Tap Delay", plain),
            .init(35, "Dry Level", "M.Tap Delay", plain),
        ]
        params += pressBlock(from: 36, section: "M.Tap Delay", mode: pressModeStd)
        params += [
            .init(40, "Delay Sw", "M.Tap Delay", .onOff),
            .init(41, "FxMtrx", "M.Tap Delay", fxMtrx),
            .init(42, "AmbienceType", "Ambience", ambienceType),
            .init(43, "Ambience Lev", "Ambience", plain),
        ]
        params += compBlock(from: 44, section: "Comp")
        return params
    }()

    static let spaceR: [ParameterDescriptor] = [
        .init(0, "Azimuth", "SpaceR", .signed(unit: "deg")),
        .init(1, "AutoRevo", "SpaceR", .enumerated([0: "OFF", 1: "RIGHT", 2: "LEFT"])),
        .init(2, "RevoSpeed", "SpaceR", .raw(unit: "rpm")),
        .init(3, "DlySw", "SpaceR", .onOff),
        .init(4, "DlyTime", "SpaceR", .bpmSyncTime),
        .init(5, "DlyFeedback", "SpaceR", plain),
        .init(6, "DlyWetLev", "SpaceR", plain),
        .init(7, "DlyDryLev", "SpaceR", plain),
    ] + pressBlock(from: 8, section: "SpaceR", mode: pressModeSpaceR) + [
        .init(12, "Phones", "SpaceR", .onOff),
        .init(13, "SpaceR Sw", "SpaceR", .onOff),
        .init(14, "FxMtrx", "SpaceR", fxMtrx),
    ] + compBlock(from: 15, section: "Comp")

    static let spaceZ: [ParameterDescriptor] = [
        .init(0, "Spread", "SpaceZ", plain),
        .init(1, "DlySw", "SpaceZ", .onOff),
        .init(2, "DTime L", "SpaceZ", .bpmSyncTime),
        .init(3, "DTime R", "SpaceZ", .bpmSyncTime),
        .init(4, "DTimeFB", "SpaceZ", .bpmSyncTime),
        .init(5, "DlyFeedback", "SpaceZ", plain),
        .init(6, "DlyWetLev", "SpaceZ", plain),
        .init(7, "DlyDryLev", "SpaceZ", plain),
        .init(8, "Phones", "SpaceZ", .onOff),
        .init(9, "SpaceZ Sw", "SpaceZ", .onOff),
        .init(10, "FxMtrx", "SpaceZ", fxMtrx),
    ] + compBlock(from: 11, section: "Comp")

    // MARK: Lookup

    /// Descriptors for a patch: instruments ignore `algoNum` (always 0).
    public static func parameters(for sel: ToneSelect, algoNum: Int) -> [ParameterDescriptor]? {
        switch sel {
        case .instrument: return instrument
        case .effect: return effects[algoNum]
        }
    }
}
