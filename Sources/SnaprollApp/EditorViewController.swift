import AppKit
import AFrameKit

/// The parameter editing surface for the currently shown domain
/// (instrument or effect): a header with the editable tone name, and the
/// parameter sections flowed into balanced columns of cards.
final class EditorViewController: NSViewController, NSTextFieldDelegate {
    var onParamChange: ((ToneSelect, _ index: Int, _ value: Int) -> Void)?
    var onRename: ((ToneSelect, String) -> Void)?
    /// Requests loading a different slot in the current domain (from the
    /// header's tone browser popover).
    var onSelectTone: ((ToneSelect, Int) -> Void)?

    private(set) var domain: ToneSelect = .instrument
    private var tones: [ToneSelect: ToneData] = [:]
    private var nums: [ToneSelect: Int] = [:]
    private var rowViews: [Int: ParameterRowView] = [:]
    private var toneNames: [ToneSelect: [String]] = [.instrument: [], .effect: []]

    // The effect compressor curve, present only while an effect's Comp card is
    // built; `compIndices` maps its parameter names to their tone-value indices.
    private var compCurveView: CompressorCurveView?
    private var compIndices: [String: Int] = [:]

    private let nameField = NSTextField(string: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let browseButton = NSButton()
    // The separator under the fixed header, hidden along with the header
    // content when no tone is loaded so the empty-state message stands alone.
    private let headerDivider = NSBox()
    private let columnsStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "Connect to an aFrame (or the mock device) to start editing")

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// A rounded, bordered container that keeps its layer colors in sync with
    /// the current appearance (light/dark).
    private final class CardView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 10
            layer?.borderWidth = 1
            applyColors()
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyColors()
        }

        private func applyColors() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = Palette.cardFill.cgColor
                layer?.borderColor = Palette.cardBorder.cgColor
            }
        }
    }

    override func loadView() {
        let content = FlippedView()

        nameField.font = .systemFont(ofSize: 22, weight: .semibold)
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
        nameField.placeholderString = "Tone name"
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(nameEdited)
        // Let the name field absorb the row width so long names don't clip; the
        // browse chevron keeps its intrinsic size at the trailing edge.
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        browseButton.title = "Browse"
        browseButton.image = NSImage(systemSymbolName: "chevron.down",
                                     accessibilityDescription: "Browse tones")
        browseButton.imagePosition = .imageTrailing
        browseButton.bezelStyle = .rounded
        browseButton.font = .systemFont(ofSize: 12)
        browseButton.target = self
        browseButton.action = #selector(browseClicked)
        browseButton.setContentHuggingPriority(.required, for: .horizontal)
        browseButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Tone name + a disclosure chevron that opens the tone browser popover.
        let nameRow = NSStackView(views: [nameField, browseButton])
        nameRow.orientation = .horizontal
        nameRow.alignment = .centerY
        nameRow.spacing = 6

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = Palette.secondaryText

        // Fixed header: the tone name, Browse button, and subtitle stay pinned
        // at the top of the editor while the parameter cards scroll beneath
        // them, so they remain visible and reachable no matter how far down the
        // player has scrolled.
        let header = NSStackView(views: [nameRow, subtitleLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2
        header.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 12, right: 24)
        header.translatesAutoresizingMaskIntoConstraints = false

        headerDivider.boxType = .separator
        headerDivider.translatesAutoresizingMaskIntoConstraints = false

        columnsStack.orientation = .horizontal
        columnsStack.alignment = .top
        columnsStack.spacing = 14
        columnsStack.distribution = .fillEqually

        emptyLabel.textColor = Palette.tertiaryText
        emptyLabel.font = .systemFont(ofSize: 14)

        // Scrolling parameter area (the header is no longer part of it).
        let outer = NSStackView(views: [emptyLabel, columnsStack])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 16
        outer.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 24, right: 24)
        outer.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(outer)

        let scroll = NSScrollView()
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(header)
        container.addSubview(headerDivider)
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            headerDivider.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: headerDivider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            outer.topAnchor.constraint(equalTo: content.topAnchor),
            outer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            // Pin the flipped document view to the scroll's content width so it
            // only scrolls vertically; height comes from `outer`.
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            columnsStack.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: -48),
            // Give the name row the full header width; the name field expands
            // within it (a leading-aligned editable field otherwise takes only
            // its intrinsic width and clips the last glyph on long names).
            nameRow.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -48),
        ])

        view = container
        rebuild()
    }

    // MARK: State input

    func showTone(_ tone: ToneData, num: Int, for sel: ToneSelect) {
        tones[sel] = tone
        nums[sel] = num
        if sel == domain { rebuild() }
    }

    func setDomain(_ sel: ToneSelect) {
        guard domain != sel else { return }
        domain = sel
        rebuild()
    }

    /// Supplies the browsable slot names for a domain (used by the header's
    /// tone browser popover).
    func setToneNames(_ list: [String], for sel: ToneSelect) {
        toneNames[sel] = list
    }

    func clear() {
        tones = [:]
        nums = [:]
        toneNames = [.instrument: [], .effect: []]
        tonePopover.performClose(nil)
        rebuild()
    }

    // MARK: Tone browser

    private lazy var tonePickerVC: TonePickerViewController = {
        let vc = TonePickerViewController()
        vc.onSelect = { [weak self] slot in
            guard let self else { return }
            self.tonePopover.performClose(nil)
            self.onSelectTone?(self.domain, slot)
        }
        return vc
    }()

    private lazy var tonePopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = tonePickerVC
        return popover
    }()

    @objc private func browseClicked() {
        tonePickerVC.configure(names: toneNames[domain] ?? [],
                               selected: nums[domain] ?? 0,
                               noun: domain == .instrument ? "instruments" : "effects")
        tonePopover.show(relativeTo: browseButton.bounds, of: browseButton, preferredEdge: .maxY)
    }

    var currentSlot: Int? { nums[domain] }

    /// The loaded slot for a specific domain (independent of which domain the
    /// editor is showing) — the group editor's "current selection" for Store.
    func currentSlot(for sel: ToneSelect) -> Int? { nums[sel] }
    var currentToneName: String? { tones[domain]?.name }

    // MARK: Randomize

    /// A scope for randomization: a display label plus the sections it covers
    /// (nil = every section).
    struct RandomizeTarget {
        let label: String
        let sections: Set<String>?
    }

    private var randomizeUndo: [Int: Int] = [:]
    private var lastRandomizeScope: String?

    /// Any randomize is undoable (used by the toolbar popover).
    var hasRandomizeUndo: Bool { !randomizeUndo.isEmpty }
    /// Only true when the last randomize was this section, so a section's Undo
    /// never claims to undo an unrelated randomize.
    func canUndoRandomize(section: String) -> Bool {
        lastRandomizeScope == section && !randomizeUndo.isEmpty
    }

    private var activeRandomizeScope: String?
    private lazy var sectionRandomizeVC: RandomizePopoverViewController = {
        let vc = RandomizePopoverViewController()
        vc.onRandomize = { [weak self] _, rate in
            guard let self, let scope = self.activeRandomizeScope else { return }
            self.randomize(target: RandomizeTarget(label: scope, sections: [scope]), rate: rate)
            self.sectionRandomizeVC.setUndoEnabled(self.canUndoRandomize(section: scope))
        }
        vc.onUndo = { [weak self] in
            self?.undoRandomize()
            self?.sectionRandomizeVC.setUndoEnabled(false)
        }
        return vc
    }()
    private lazy var sectionRandomizePopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = sectionRandomizeVC
        return popover
    }()

    @objc private func sectionDiceClicked(_ sender: NSButton) {
        guard let section = sender.identifier?.rawValue else { return }
        activeRandomizeScope = section
        sectionRandomizeVC.configureFixed(title: "Randomize \(section)",
                                          canUndo: canUndoRandomize(section: section))
        sectionRandomizePopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    /// The targets available for the current tone: only sections that actually
    /// contain randomizable parameters (per the reference manual), plus MSX
    /// (Main+Sub+Xtra) for instruments, plus All.
    func randomizeTargets() -> [RandomizeTarget] {
        guard let tone = tones[domain],
              let descriptors = ParameterMap.parameters(for: domain, algoNum: tone.algoNum) else { return [] }
        let inRange = descriptors.filter { $0.index < tone.values.count }
        let order = RandomizationRules.randomizableSections(in: inRange, domain: domain)
        guard !order.isEmpty else { return [] }
        var targets = order.map { RandomizeTarget(label: $0, sections: [$0]) }
        if domain == .instrument, ["Main", "Sub", "Xtra"].allSatisfy(order.contains) {
            targets.append(RandomizeTarget(label: "MSX (Main+Sub+Xtra)", sections: ["Main", "Sub", "Xtra"]))
        }
        targets.append(RandomizeTarget(label: "All", sections: nil))
        return targets
    }

    /// Randomizes the target's parameters by `rate` (0…100), excluding the
    /// parameters the reference manual fixes or excludes ("(Fix)" / "---"),
    /// keeping every value inside its hardware range, and streaming each change
    /// like a normal edit. Records a one-level undo snapshot.
    func randomize(target: RandomizeTarget, rate: Double) {
        guard let tone = tones[domain],
              let descriptors = ParameterMap.parameters(for: domain, algoNum: tone.algoNum) else { return }
        var snapshot = [Int: Int]()
        for d in descriptors where d.index < tone.values.count {
            if let sections = target.sections, !sections.contains(d.section) { continue }
            let current = tone.values[d.index]
            guard RandomizationRules.shouldRandomize(d, currentValue: current, domain: domain) else { continue }
            guard let range = ParameterMap.range(for: domain, algoNum: tone.algoNum, index: d.index),
                  range.lowerBound < range.upperBound else { continue }
            let value = Randomizer.blend(current: current, randomTarget: Int.random(in: range),
                                         rate: rate / 100, range: range)
            guard value != current else { continue }
            snapshot[d.index] = current
            applyRandomized(index: d.index, value: value)
        }
        if !snapshot.isEmpty {
            randomizeUndo = snapshot
            lastRandomizeScope = target.label
        }
    }

    /// Restores the values captured before the last randomize.
    func undoRandomize() {
        for (index, value) in randomizeUndo { applyRandomized(index: index, value: value) }
        randomizeUndo = [:]
        lastRandomizeScope = nil
    }

    private func applyRandomized(index: Int, value: Int) {
        tones[domain]?.values[index] = value
        rowViews[index]?.apply(value: value)
        onParamChange?(domain, index, value)
    }

    /// Recomputes the compressor curve from the effect tone's current comp
    /// values. No-op unless an effect Comp card (and thus the plot) is built.
    private func updateCompCurve() {
        guard let curve = compCurveView, let tone = tones[.effect] else { return }
        func value(_ name: String) -> Int? {
            guard let index = compIndices[name], index < tone.values.count else { return nil }
            return tone.values[index]
        }
        let ratioCode = value("CompRatio") ?? 10
        let kneeCode = value("CompKnee") ?? 0
        curve.update(
            thresholdDb: Double(value("CompThrs") ?? 0) / 10,
            ratio: ParameterMap.compRatioValues[ratioCode] ?? 1,
            kneeWidthDb: kneeCode == 2 ? 12 : (kneeCode == 1 ? 6 : 0),
            makeupGainDb: Double(value("CompGain") ?? 0) / 10,
            isOn: (value("Comp Sw") ?? 0) != 0)
    }

    // MARK: Building

    private func rebuild() {
        randomizeUndo = [:]
        lastRandomizeScope = nil
        rowViews = [:]
        compCurveView = nil
        compIndices = [:]
        columnsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard let tone = tones[domain] else {
            nameField.stringValue = ""
            subtitleLabel.stringValue = ""
            nameField.isHidden = true
            browseButton.isHidden = true
            subtitleLabel.isHidden = true
            headerDivider.isHidden = true
            emptyLabel.isHidden = false
            return
        }
        nameField.isHidden = false
        browseButton.isHidden = false
        subtitleLabel.isHidden = false
        headerDivider.isHidden = false
        browseButton.toolTip = domain == .instrument ? "Browse instruments" : "Browse effects"
        emptyLabel.isHidden = true
        nameField.stringValue = tone.name

        let slot = nums[domain].map { String(format: "%02d", $0 + 1) } ?? "—"
        if domain == .instrument {
            subtitleLabel.stringValue = "Instrument \(slot) · \(tone.values.count) parameters"
        } else {
            let algoName = ParameterMap.effectAlgoNames[tone.algoNum] ?? "Algorithm \(tone.algoNum)"
            subtitleLabel.stringValue = "Effect \(slot) · \(algoName) · \(tone.values.count) parameters"
        }

        guard let descriptors = ParameterMap.parameters(for: domain, algoNum: tone.algoNum) else { return }

        // Group into sections preserving first-appearance order (Xtra spans
        // two index ranges and merges into one card).
        var sectionOrder = [String]()
        var sections = [String: [ParameterDescriptor]]()
        for d in descriptors where d.index < tone.values.count {
            if sections[d.section] == nil { sectionOrder.append(d.section) }
            sections[d.section, default: []].append(d)
        }

        // Flow section cards into columns sequentially, balancing row counts.
        let totalRows = descriptors.count
        let columnCount = totalRows > 44 ? 3 : 2
        let targetRows = (totalRows + columnCount - 1) / columnCount
        var columns: [[NSView]] = [[]]
        var rowsInColumn = 0
        for section in sectionOrder {
            let params = sections[section]!
            if rowsInColumn > 0, rowsInColumn + params.count / 2 > targetRows,
               columns.count < columnCount {
                columns.append([])
                rowsInColumn = 0
            }
            columns[columns.count - 1].append(makeCard(section: section, params: params, tone: tone))
            rowsInColumn += params.count + 2
        }

        for column in columns {
            let stack = NSStackView(views: column)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 14
            stack.setHuggingPriority(.defaultHigh, for: .vertical)
            for card in column {
                card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            // Columns differ in height, and a card has no intrinsic height of
            // its own (its inner stack is pinned to both card edges). Whatever
            // vertical slack a column is given would otherwise be absorbed by
            // an arbitrary card, padding it out or — before its header learned
            // to hug — pushing its rows out of view. This spacer hugs far more
            // weakly than any card, so it soaks up the slack instead.
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .vertical)
            stack.addArrangedSubview(spacer)
            columnsStack.addArrangedSubview(stack)
        }

        updateCompCurve()
    }

    private func makeCard(section: String, params: [ParameterDescriptor], tone: ToneData) -> NSView {
        let title = NSTextField(labelWithString: section.uppercased())
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = Palette.sectionTitle

        // A dice in each section header randomizes just that section, sized to
        // match the toolbar's Randomize dice. Only shown for sections that
        // actually have randomizable parameters (per the reference manual);
        // fixed/excluded sections like Mixer, Pressure, Ambience get no dice.
        var headerViews: [NSView] = [title]
        if params.contains(where: { RandomizationRules.isRandomizable($0, domain: domain) }) {
            let diceImage = NSImage(systemSymbolName: "die.face.5", accessibilityDescription: "Randomize \(section)")!
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            let dice = NSButton(image: diceImage!, target: self, action: #selector(sectionDiceClicked(_:)))
            dice.isBordered = false
            dice.imagePosition = .imageOnly
            dice.identifier = NSUserInterfaceItemIdentifier(section)
            dice.contentTintColor = Palette.controlGlyph
            dice.toolTip = "Randomize the \(section) section"
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            headerViews += [spacer, dice]
        }
        let header = NSStackView(views: headerViews)
        header.orientation = .horizontal
        header.alignment = .centerY
        // Keep the title row at its natural height rather than letting it soak
        // up any vertical slack the card is given.
        header.setHuggingPriority(.defaultHigh, for: .vertical)

        var views: [NSView] = [header]

        // Effects carry a compressor block; show the live transfer-curve monitor
        // atop its card, mirroring the original aFrameEdit "Comp Curve".
        if domain == .effect, section == "Comp" {
            compIndices = Dictionary(params.map { ($0.name, $0.index) }, uniquingKeysWith: { a, _ in a })
            let curve = CompressorCurveView()
            curve.translatesAutoresizingMaskIntoConstraints = false
            curve.heightAnchor.constraint(equalToConstant: 180).isActive = true
            curve.toolTip = "Compressor input → output curve"
            compCurveView = curve
            views.append(curve)
        }

        for d in params {
            let row = ParameterRowView(
                descriptor: d,
                range: ParameterMap.range(for: domain, algoNum: tone.algoNum, index: d.index),
                value: d.index < tone.values.count ? tone.values[d.index] : 0)
            // Mute readouts fold in the tone's global Mute Sens for their
            // "ON(n)" form; feed the live value in and render once with it.
            if case .muteSensitivity = d.display {
                row.contextProvider = { [weak self] in
                    guard let self, let tone = self.tones[self.domain],
                          tone.values.indices.contains(ParameterMap.muteSensIndex)
                    else { return .init() }
                    return .init(globalMuteSens: tone.values[ParameterMap.muteSensIndex])
                }
                row.apply(value: row.value)
            }
            row.onChange = { [weak self] value in
                guard let self else { return }
                self.tones[self.domain]?.values[d.index] = value
                self.onParamChange?(self.domain, d.index, value)
                if d.section == "Comp" { self.updateCompCurve() }
                // Editing Mute Sens changes every mute row's "ON(n)" readout.
                if d.index == ParameterMap.muteSensIndex {
                    for r in self.rowViews.values where r.descriptor.display == .muteSensitivity {
                        r.apply(value: r.value)
                    }
                }
            }
            rowViews[d.index] = row
            views.append(row)
        }

        let inner = NSStackView(views: views)
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 2
        inner.setCustomSpacing(8, after: header)
        inner.translatesAutoresizingMaskIntoConstraints = false

        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])
        // Pin every row and the header to the card width so the header's dice
        // sits flush right and the parameter rows fill the card.
        for v in views {
            v.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        }
        return card
    }

    // MARK: Rename

    @objc private func nameEdited() {
        guard tones[domain] != nil else { return }
        let name = nameField.stringValue
        tones[domain]?.name = name
        onRename?(domain, name)
    }
}
