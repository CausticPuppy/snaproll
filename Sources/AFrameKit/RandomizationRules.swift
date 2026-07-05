import Foundation

/// Which parameters the aFrame's randomization touches, per the v2.01 reference
/// manual ("Instrument and effect parameters", pp. 33–43).
///
/// The manual marks each parameter with a code:
///   `***`  — changed according to the randomization level.
///   `---`  — excluded from randomization (never changes).
///   `(Fix)`— pinned to a fixed initial value, so it never changes either.
///
/// This is the single source of truth for the editor's Randomize feature; it is
/// pure so it can be unit-tested against the manual's tables.
public enum RandomizationRules {

    // MARK: Instrument

    /// The only instrument sections the hardware randomizes are the three timbre
    /// layers. Dry EQ, Pressure, Mixer and Master parameters are never touched
    /// ("In general, when randomization is applied, the Instrument-mixer
    /// parameters do not change"; the pressure and dry sections aren't among the
    /// timbre-layer target sets at all).
    private static let instrumentSections: Set<String> = ["Main", "Sub", "Xtra"]

    /// Named timbre-layer parameters that stay fixed even though their section is
    /// randomized (manual "(Fix)").
    private static let instrumentFixed: Set<String> = [
        "Main In", "Sub In", "Xtra In",       // C50/E50
        "MainMute", "Sub Mute", "XtraMute",   // OFF
        "Main OD", "Sub OD",                  // 0
        "XtraJxCarLev",                       // 100
    ]

    // MARK: Effects

    /// Effect sections excluded wholesale: "Ambience effect parameters and
    /// Compression effect parameters are also unchanged by randomization."
    private static let effectExcludedSections: Set<String> = ["Ambience", "Comp"]

    /// Named effect parameters that are fixed or excluded ("(Fix)" / "---").
    /// Pressure parameters are handled separately by name prefix below.
    private static let effectExcludedNames: Set<String> = [
        "Pan Spread", "Wet Level", "Dry Level",   // (Fix)
        "DlyWetLev", "DlyDryLev",                 // SpaceR/SpaceZ (Fix)
        "FxMtrx", "Phones",                       // ---
    ]

    /// Whether `descriptor` ever participates in randomization, independent of
    /// its current value.
    public static func isRandomizable(_ descriptor: ParameterDescriptor,
                                      domain: ToneSelect) -> Bool {
        if case .onOff = descriptor.display { return false }  // switches never randomize
        switch domain {
        case .instrument:
            guard instrumentSections.contains(descriptor.section) else { return false }
            return !instrumentFixed.contains(descriptor.name)
        case .effect:
            if effectExcludedSections.contains(descriptor.section) { return false }
            if effectExcludedNames.contains(descriptor.name) { return false }
            // PressMode / PressSens / PressAtck / PressRele / PressSw are all "---".
            if descriptor.name.hasPrefix("Press") { return false }
            return true
        }
    }

    /// Whether the parameter should change for its *current* value, layering the
    /// manual's value-dependent notes on top of `isRandomizable`. Delay times
    /// that are showing a tempo-synced ("BPM") value — encoded as a non-positive
    /// value — "do not change".
    public static func shouldRandomize(_ descriptor: ParameterDescriptor,
                                       currentValue: Int,
                                       domain: ToneSelect) -> Bool {
        guard isRandomizable(descriptor, domain: domain) else { return false }
        if case .bpmSyncTime = descriptor.display, currentValue <= 0 { return false }
        return true
    }

    /// The sections (in first-appearance order) that contain at least one
    /// randomizable parameter — used to decide which section dice and picker
    /// targets to offer.
    public static func randomizableSections(in descriptors: [ParameterDescriptor],
                                            domain: ToneSelect) -> [String] {
        var seen = Set<String>()
        var order = [String]()
        for d in descriptors where isRandomizable(d, domain: domain) {
            if seen.insert(d.section).inserted { order.append(d.section) }
        }
        return order
    }
}
