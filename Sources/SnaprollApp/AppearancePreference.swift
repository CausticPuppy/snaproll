import AppKit

/// The user's chosen window appearance. `auto` follows the system setting; the
/// other two force a specific mode regardless of the system. Persisted in
/// `UserDefaults` so the choice survives relaunches.
enum AppearancePreference: String, CaseIterable {
    case auto
    case light
    case dark

    private static let defaultsKey = "appearance"

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The `NSAppearance` to install, or `nil` for `auto` (which lets the app
    /// inherit the system appearance).
    private var nsAppearance: NSAppearance? {
        switch self {
        case .auto: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static var current: AppearancePreference {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultsKey)
            return raw.flatMap(AppearancePreference.init) ?? .auto
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            newValue.apply()
        }
    }

    /// Installs this appearance on the running application.
    func apply() {
        NSApp.appearance = nsAppearance
    }
}
