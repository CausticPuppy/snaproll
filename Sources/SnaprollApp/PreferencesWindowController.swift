import AppKit

/// Simple, single-pane preferences window. Currently just the appearance
/// (light/dark/auto) picker; more panes can be added as the app grows.
final class PreferencesWindowController: NSWindowController {
    private let appearanceControl = NSSegmentedControl(
        labels: AppearancePreference.allCases.map(\.label),
        trackingMode: .selectOne, target: nil, action: nil)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 130),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildContent()
    }

    private func buildContent() {
        let heading = NSTextField(labelWithString: "Appearance")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)

        appearanceControl.target = self
        appearanceControl.action = #selector(appearanceChanged)
        appearanceControl.segmentDistribution = .fillEqually
        syncSelection()

        let caption = NSTextField(labelWithString: "“Auto” follows the macOS system setting.")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [heading, appearanceControl, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            appearanceControl.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window?.contentView = content
    }

    /// Reflects the persisted preference in the segmented control.
    private func syncSelection() {
        if let idx = AppearancePreference.allCases.firstIndex(of: .current) {
            appearanceControl.selectedSegment = idx
        }
    }

    @objc private func appearanceChanged() {
        let idx = appearanceControl.selectedSegment
        guard AppearancePreference.allCases.indices.contains(idx) else { return }
        AppearancePreference.current = AppearancePreference.allCases[idx]
    }

    @objc func showPreferences(_ sender: Any?) {
        syncSelection()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
