import AppKit
import AFrameKit

/// The parameter editing surface for the currently shown domain
/// (instrument or effect): a header with the editable tone name, and the
/// parameter sections flowed into balanced columns of cards.
final class EditorViewController: NSViewController, NSTextFieldDelegate {
    var onParamChange: ((ToneSelect, _ index: Int, _ value: Int) -> Void)?
    var onRename: ((ToneSelect, String) -> Void)?

    private(set) var domain: ToneSelect = .instrument
    private var tones: [ToneSelect: ToneData] = [:]
    private var nums: [ToneSelect: Int] = [:]
    private var rowViews: [Int: ParameterRowView] = [:]

    private let nameField = NSTextField(string: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
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
                layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
                layer?.borderColor = NSColor.separatorColor.cgColor
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

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor

        let header = NSStackView(views: [nameField, subtitleLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2

        columnsStack.orientation = .horizontal
        columnsStack.alignment = .top
        columnsStack.spacing = 14
        columnsStack.distribution = .fillEqually

        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 14)

        let outer = NSStackView(views: [header, emptyLabel, columnsStack])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 16
        outer.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 24, right: 24)
        outer.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(outer)

        let scroll = NSScrollView()
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        scroll.automaticallyAdjustsContentInsets = false

        NSLayoutConstraint.activate([
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
            // Give the tone-name field the full content width; a leading-aligned
            // editable field otherwise takes only its intrinsic width and clips
            // the last glyph on long names.
            nameField.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: -48),
        ])

        view = scroll
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

    func clear() {
        tones = [:]
        nums = [:]
        rebuild()
    }

    var currentSlot: Int? { nums[domain] }
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

    /// The targets available for the current tone: each section, plus MSX
    /// (Main+Sub+Xtra) for instruments, plus All.
    func randomizeTargets() -> [RandomizeTarget] {
        guard let tone = tones[domain],
              let descriptors = ParameterMap.parameters(for: domain, algoNum: tone.algoNum) else { return [] }
        var order = [String]()
        for d in descriptors where d.index < tone.values.count {
            if !order.contains(d.section) { order.append(d.section) }
        }
        var targets = order.map { RandomizeTarget(label: $0, sections: [$0]) }
        if domain == .instrument, ["Main", "Sub", "Xtra"].allSatisfy(order.contains) {
            targets.append(RandomizeTarget(label: "MSX (Main+Sub+Xtra)", sections: ["Main", "Sub", "Xtra"]))
        }
        targets.append(RandomizeTarget(label: "All", sections: nil))
        return targets
    }

    /// Randomizes the target's parameters by `rate` (0…100), excluding on/off
    /// switches, keeping every value inside its hardware range, and streaming
    /// each change like a normal edit. Records a one-level undo snapshot.
    func randomize(target: RandomizeTarget, rate: Double) {
        guard let tone = tones[domain],
              let descriptors = ParameterMap.parameters(for: domain, algoNum: tone.algoNum) else { return }
        var snapshot = [Int: Int]()
        for d in descriptors where d.index < tone.values.count {
            if case .onOff = d.display { continue }
            if let sections = target.sections, !sections.contains(d.section) { continue }
            guard let range = ParameterMap.range(for: domain, algoNum: tone.algoNum, index: d.index),
                  range.lowerBound < range.upperBound else { continue }
            let current = tone.values[d.index]
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

    // MARK: Building

    private func rebuild() {
        randomizeUndo = [:]
        lastRandomizeScope = nil
        rowViews = [:]
        columnsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard let tone = tones[domain] else {
            nameField.stringValue = ""
            subtitleLabel.stringValue = ""
            nameField.isHidden = true
            emptyLabel.isHidden = false
            return
        }
        nameField.isHidden = false
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
            for card in column {
                card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            columnsStack.addArrangedSubview(stack)
        }
    }

    private func makeCard(section: String, params: [ParameterDescriptor], tone: ToneData) -> NSView {
        let title = NSTextField(labelWithString: section.uppercased())
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .tertiaryLabelColor

        // A dice in each section header randomizes just that section, sized to
        // match the toolbar's Randomize dice.
        let diceImage = NSImage(systemSymbolName: "die.face.5", accessibilityDescription: "Randomize \(section)")!
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        let dice = NSButton(image: diceImage!, target: self, action: #selector(sectionDiceClicked(_:)))
        dice.isBordered = false
        dice.imagePosition = .imageOnly
        dice.identifier = NSUserInterfaceItemIdentifier(section)
        dice.contentTintColor = .secondaryLabelColor
        dice.toolTip = "Randomize the \(section) section"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [title, spacer, dice])
        header.orientation = .horizontal
        header.alignment = .centerY

        var views: [NSView] = [header]
        for d in params {
            let row = ParameterRowView(
                descriptor: d,
                range: ParameterMap.range(for: domain, algoNum: tone.algoNum, index: d.index),
                value: d.index < tone.values.count ? tone.values[d.index] : 0)
            row.onChange = { [weak self] value in
                guard let self else { return }
                self.tones[self.domain]?.values[d.index] = value
                self.onParamChange?(self.domain, d.index, value)
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
