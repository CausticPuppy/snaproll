import Foundation

/// The two representations of an instrument Tune parameter (Main/Sub/Xtra).
///
/// The raw Int16 stored in DSP_PATCH.Data[] carries both modes in one field:
/// positive = absolute frequency in Hz; negative = a note + cents offset,
/// encoded `-(midi × 100 + cents)`. Hardware-confirmed against VER.2.00:
/// captures/20260708-204307/tune_probe.txt.
public enum TuneValue: Equatable {
    /// Absolute frequency, `TuneMap.hzRange` (16…12544 Hz).
    case hz(Int)
    /// MIDI note (`TuneMap.midiRange`, 12 = C0 … 127 = G9) + cents
    /// (`TuneMap.centsRange`, −50…+49).
    case note(midi: Int, cents: Int)

    public init(raw: Int) {
        if raw >= 0 {
            self = .hz(raw)
        } else {
            let m = -raw
            let midi = Int((Double(m) / 100.0).rounded())
            self = .note(midi: midi, cents: m - midi * 100)
        }
    }

    public var raw: Int {
        switch self {
        case .hz(let v): return v
        case .note(let midi, let cents): return -(midi * 100 + cents)
        }
    }
}

/// Rendering, parsing, and Hz↔note conversion for `TuneValue`.
public enum TuneMap {
    public static let hzRange = 16...12544
    public static let midiRange = 12...127        // C0 … G9
    public static let centsRange = -50...49

    private static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private static let semitoneOf: [Character: Int] =
        ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]

    /// e.g. midi 12 → "C0", 69 → "A4", 127 → "G9".
    public static func noteName(midi: Int) -> String {
        let pc = ((midi % 12) + 12) % 12
        return names[pc] + "\(midi / 12 - 1)"
    }

    /// Signed, zero-padded cents: 0 → "+00", −50 → "-50", 49 → "+49".
    public static func centsString(_ c: Int) -> String { String(format: "%+03d", c) }

    /// The hardware's own readout, minus the LCD's column padding:
    /// "440Hz" for the Hz zone, "A4/+00" for the note zone.
    public static func label(raw: Int) -> String {
        switch TuneValue(raw: raw) {
        case .hz(let v): return "\(v)Hz"
        case .note(let midi, let cents): return noteName(midi: midi) + "/" + centsString(cents)
        }
    }

    /// Inverts `label`, accepting either "<hz>[ Hz]" or "<note>[/][±cents]"
    /// (case-insensitive, cents and the slash optional). Returns the raw value,
    /// or nil if it can't be interpreted or falls outside a valid band.
    public static func parse(_ input: String) -> Int? {
        let s = input.trimmingCharacters(in: .whitespaces)
        guard let first = s.first else { return nil }
        if semitoneOf[Character(first.uppercased())] != nil {
            return parseNote(Array(s))
        }
        var t = s
        if t.count >= 2, t.suffix(2).lowercased() == "hz" { t = String(t.dropLast(2)) }
        return Int(t.trimmingCharacters(in: .whitespaces))
    }

    private static func parseNote(_ chars: [Character]) -> Int? {
        var i = 0
        guard let base = semitoneOf[Character(chars[i].uppercased())] else { return nil }
        i += 1
        var semis = base
        if i < chars.count, chars[i] == "#" { semis += 1; i += 1 }
        else if i < chars.count, chars[i] == "b" { semis -= 1; i += 1 }

        var octStr = ""
        if i < chars.count, chars[i] == "-" { octStr.append("-"); i += 1 }
        while i < chars.count, chars[i].isNumber { octStr.append(chars[i]); i += 1 }
        guard let oct = Int(octStr) else { return nil }
        let midi = (oct + 1) * 12 + semis
        guard midiRange.contains(midi) else { return nil }

        var cents = 0
        if i < chars.count {
            if chars[i] == "/" { i += 1 }
            let rest = String(chars[i...]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty {
                guard let c = Int(rest) else { return nil }
                cents = c
            }
        }
        guard centsRange.contains(cents) else { return nil }
        return TuneValue.note(midi: midi, cents: cents).raw
    }

    /// Nearest in-range Hz for a note+cents (used when switching a control from
    /// note mode to Hz mode so the pitch is preserved).
    public static func hz(forMidi midi: Int, cents: Int) -> Int {
        let semis = Double(midi - 69) + Double(cents) / 100.0
        let f = 440.0 * pow(2.0, semis / 12.0)
        return min(hzRange.upperBound, max(hzRange.lowerBound, Int(f.rounded())))
    }

    /// Nearest note+cents for a frequency (Hz→note mode switch).
    public static func nearestNote(forHz hz: Int) -> (midi: Int, cents: Int) {
        let midiF = 69.0 + 12.0 * log2(Double(hz) / 440.0)
        let midi = min(midiRange.upperBound, max(midiRange.lowerBound, Int(midiF.rounded())))
        let cents = min(centsRange.upperBound, max(centsRange.lowerBound,
                                                   Int(((midiF - Double(midi)) * 100).rounded())))
        return (midi, cents)
    }
}
