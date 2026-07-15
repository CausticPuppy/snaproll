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
    /// Requests saving the current tone to its project slot (header Save, ⌘S).
    var onSave: (() -> Void)?
    /// Requests opening the full Monitor window (clicking an embedded meter —
    /// the pressure traces or the Master output meters).
    var onOpenMonitor: (() -> Void)?

    /// The group/tone navigator, embedded in the fixed header row. Owned here
    /// for layout; the main window controller wires its callbacks and state.
    let groupNav = GroupNavView()

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
    private let saveButton = NSButton()
    private let headerDivider = NSBox()
    private let columnsStack = NSStackView()
    /// The scrolling content column: empty label, parameter columns, and (for
    /// instruments) the mixer console band appended during rebuild.
    private let contentStack = NSStackView()

    // The mixer console band and the live views embedded in the layout: the
    // Pressure card's pitch/mute traces and the Master strip's output meters.
    // All are rebuilt with the cards and fed by `updateMeters`.
    private var consoleCard: NSView?
    private var pitchChart: StripChartView?
    private var muteChart: StripChartView?
    private var masterMeters: StripMeterPairView?
    #if DEBUG
    private let emptyLabel = NSTextField(labelWithString: "Connect to an aFrame (or the mock device) to start editing")
    #else
    private let emptyLabel = NSTextField(labelWithString: "Connect to an aFrame to start editing")
    #endif

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
        nameField.lineBreakMode = .byTruncatingTail
        // The name hugs its content (Browse/Save sit right beside it) but
        // yields first when the header runs out of room, truncating rather
        // than squeezing the nav controls.
        nameField.setContentCompressionResistancePriority(.init(740), for: .horizontal)

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

        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.font = .systemFont(ofSize: 12)
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = [.command]
        saveButton.toolTip = "Write the edit buffer to its project slot (⌘S)"
        saveButton.setContentHuggingPriority(.required, for: .horizontal)
        saveButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = Palette.secondaryText
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.init(740), for: .horizontal)

        // Name over subtitle, forming the header's leading block.
        let nameBlock = NSStackView(views: [nameField, subtitleLabel])
        nameBlock.orientation = .vertical
        nameBlock.alignment = .leading
        nameBlock.spacing = 1

        // Fixed header: one bar with the tone identity (name, subtitle,
        // Browse, Save) on the left and the group/tone navigator filling the
        // right. It stays pinned while the parameter cards scroll beneath, so
        // everything up here remains reachable at any scroll position.
        groupNav.setContentHuggingPriority(.init(1), for: .horizontal)
        // GroupNavView only centers its children vertically, so it needs an
        // explicit height for the stack to lay it out.
        groupNav.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let header = NSStackView(views: [nameBlock, browseButton, saveButton, groupNav])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.setCustomSpacing(12, after: nameBlock)
        header.edgeInsets = NSEdgeInsets(top: 8, left: 24, bottom: 8, right: 0)
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
        let outer = contentStack
        outer.addArrangedSubview(emptyLabel)
        outer.addArrangedSubview(columnsStack)
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 16
        outer.setCustomSpacing(14, after: columnsStack)
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
            // Constant height so the bar doesn't jump when the tone-identity
            // controls hide in the disconnected state.
            header.heightAnchor.constraint(equalToConstant: 58),

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
        pitchChart = nil
        muteChart = nil
        masterMeters = nil
        consoleCard?.removeFromSuperview()
        consoleCard = nil
        columnsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard let tone = tones[domain] else {
            nameField.stringValue = ""
            subtitleLabel.stringValue = ""
            nameField.isHidden = true
            subtitleLabel.isHidden = true
            browseButton.isHidden = true
            saveButton.isHidden = true
            emptyLabel.isHidden = false
            return
        }
        nameField.isHidden = false
        subtitleLabel.isHidden = false
        browseButton.isHidden = false
        saveButton.isHidden = false
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

        // Instruments model the original editor's physical-mixer layout: every
        // Mixer/Master channel param (pans + level/send faders) leaves the
        // cards for one full-width six-strip console band below the columns.
        // (ParameterMap sections are untouched — this is purely a UI
        // regrouping, so the randomization rules keyed on manual sections
        // still hold.)
        var consoleParams: [ParameterDescriptor] = []
        if domain == .instrument {
            consoleParams = (sections["Mixer"] ?? []) + (sections["Master"] ?? [])
            sections["Mixer"] = nil
            sections["Master"] = nil
            sectionOrder.removeAll { $0 == "Mixer" || $0 == "Master" }
        }

        // A card's approximate height in row units, for balancing and for the
        // proportional stretch below (rows + header, plus embedded extras).
        func weight(_ section: String) -> Int {
            var w = (sections[section]?.count ?? 0) + 2
            if domain == .instrument, section == "Pressure" { w += 6 }  // live graphs
            if domain == .effect, section == "Comp" { w += 7 }          // curve plot
            return w
        }

        // Instruments always have the same six sections, so their column plan
        // is fixed (matching the console-grid design); effects vary by
        // algorithm and flow sequentially into weight-balanced columns.
        var columnPlan: [[String]]
        if domain == .instrument {
            let plan = [["Main", "Dry"], ["Xtra"], ["Sub", "Pressure"]]
            columnPlan = plan.map { $0.filter { sections[$0] != nil } }.filter { !$0.isEmpty }
            let planned = Set(plan.flatMap { $0 })
            let extras = sectionOrder.filter { !planned.contains($0) }
            if !extras.isEmpty { columnPlan.append(extras) }
        } else {
            let totalWeight = sectionOrder.reduce(0) { $0 + weight($1) }
            let columnCount = descriptors.count > 44 ? 3 : 2
            let targetRows = (totalWeight + columnCount - 1) / columnCount
            columnPlan = [[]]
            var rowsInColumn = 0
            for section in sectionOrder {
                if rowsInColumn > 0, rowsInColumn + weight(section) / 2 > targetRows,
                   columnPlan.count < columnCount {
                    columnPlan.append([])
                    rowsInColumn = 0
                }
                columnPlan[columnPlan.count - 1].append(section)
                rowsInColumn += weight(section)
            }
        }

        for columnSections in columnPlan {
            let cards = columnSections.map {
                makeCard(section: $0, params: sections[$0]!, tone: tone)
            }
            let stack = NSStackView(views: cards)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 14
            for card in cards {
                card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            columnsStack.addArrangedSubview(stack)
            // Every column fills the row height (set by the tallest column's
            // natural size), so all columns end on one line. The slack goes to
            // the cards in proportion to their content — the low-priority
            // multiplier constraints below steer it — and inside each card the
            // rows stack (.equalSpacing) turns it into breathing room.
            stack.heightAnchor.constraint(equalTo: columnsStack.heightAnchor).isActive = true
            let columnWeight = columnSections.reduce(0) { $0 + weight($1) }
            for (card, section) in zip(cards, columnSections) where columnWeight > 0 {
                let share = card.heightAnchor.constraint(
                    equalTo: stack.heightAnchor,
                    multiplier: CGFloat(weight(section)) / CGFloat(columnWeight))
                share.priority = .init(400)
                share.isActive = true
            }
        }

        if !consoleParams.isEmpty {
            let console = makeConsole(consoleParams, tone: tone)
            contentStack.addArrangedSubview(console)
            console.widthAnchor.constraint(equalTo: columnsStack.widthAnchor).isActive = true
            consoleCard = console
        }

        updateCompCurve()
    }

    /// Feeds the live meter sample into whatever monitoring views the current
    /// layout carries (pressure traces, master output meters).
    func updateMeters(peak: PeakLevels, pressure: PressureLevels) {
        pitchChart?.append(Double(pressure.pitch))
        muteChart?.append(Double(pressure.mute))
        masterMeters?.update(l: peak.outL, r: peak.outR)
    }

    private func makeRow(_ d: ParameterDescriptor, tone: ToneData) -> ParameterRowView {
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
        return row
    }

    // MARK: Mixer console

    /// The console strips in signal order. `key` matches the parameter-name
    /// stem after "Mix" (spaces removed, so "MixSub Pan" lands on SUB).
    private static let stripOrder: [(key: String, title: String)] = [
        ("Main", "MAIN"), ("Sub", "SUB"), ("Xtra", "XTRA"),
        ("DryC", "DRY C"), ("DryE", "DRY E"), ("Master", "MASTER"),
    ]

    private static func stripKey(for name: String) -> String? {
        let stem = name.hasPrefix("Mix") ? String(name.dropFirst(3)).replacingOccurrences(of: " ", with: "") : name
        // Longest match first so "DryC" isn't claimed by a shorter key.
        return stripOrder.map(\.key).sorted { $0.count > $1.count }
            .first { stem.hasPrefix($0) }
    }

    /// The full-width mixer console band: one channel strip per timbre
    /// (Main / Sub / Xtra / Dry C / Dry E / Master), each with its pan control
    /// over its Lev/Snd faders; Master also carries the live L/R output meters.
    private func makeConsole(_ params: [ParameterDescriptor], tone: ToneData) -> NSView {
        var grouped = [String: [ParameterDescriptor]]()
        for d in params {
            grouped[Self.stripKey(for: d.name) ?? "Master", default: []].append(d)
        }

        let strips = Self.stripOrder.compactMap { key, title -> NSView? in
            guard let stripParams = grouped[key] else { return nil }
            return makeStrip(title: title, params: stripParams,
                             withMeters: key == "Master", tone: tone)
        }

        let title = NSTextField(labelWithString: "MIXER")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = Palette.sectionTitle

        let stripsRow = NSStackView(views: strips)
        stripsRow.orientation = .horizontal
        stripsRow.alignment = .top
        stripsRow.distribution = .fillEqually
        stripsRow.spacing = 8

        let inner = NSStackView(views: [title, stripsRow])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 8
        inner.translatesAutoresizingMaskIntoConstraints = false
        stripsRow.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true

        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])
        return card
    }

    /// One console channel strip: centered title, pan control(s), then the
    /// vertical faders (and, for Master, the L/R output meters) side by side.
    private func makeStrip(title: String, params: [ParameterDescriptor],
                           withMeters: Bool, tone: ToneData) -> NSView {
        func isPan(_ d: ParameterDescriptor) -> Bool {
            d.name.hasSuffix("Pan") || d.name.hasSuffix("Bal")
        }
        func wire(_ d: ParameterDescriptor) -> (Int) -> Void {
            { [weak self] value in
                guard let self else { return }
                self.tones[self.domain]?.values[d.index] = value
                self.onParamChange?(self.domain, d.index, value)
            }
        }

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 10, weight: .bold)
        titleLabel.textColor = Palette.sectionTitle
        titleLabel.alignment = .center

        var views: [NSView] = [titleLabel]

        for d in params where isPan(d) {
            let pan = CompactPanView(descriptor: d,
                                     value: d.index < tone.values.count ? tone.values[d.index] : 64)
            pan.onChange = wire(d)
            views.append(pan)
        }

        var faderViews: [NSView] = params.filter { !isPan($0) }
            .sorted { !$0.name.hasSuffix("Snd") && $1.name.hasSuffix("Snd") }  // Lev before Snd
            .map { d in
                let fader = VerticalFaderView(
                    title: d.name.hasSuffix("Snd") ? "Snd" : "Lev",
                    descriptor: d,
                    range: ParameterMap.range(for: domain, algoNum: tone.algoNum, index: d.index),
                    value: d.index < tone.values.count ? tone.values[d.index] : 0)
                fader.onChange = wire(d)
                return fader
            }
        if withMeters {
            let meters = StripMeterPairView()
            meters.onOpen = { [weak self] in self?.onOpenMonitor?() }
            masterMeters = meters
            faderViews.append(meters)
        }
        if !faderViews.isEmpty {
            let row = NSStackView(views: faderViews)
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            views.append(row)
        }

        let strip = NSStackView(views: views)
        strip.orientation = .vertical
        strip.alignment = .centerX
        strip.spacing = 6
        // Keep the strip's content clustered at the top: without this, a strip
        // stretched to match a taller neighbor lets its rows drift downward.
        strip.setHuggingPriority(.required, for: .vertical)
        for v in views.dropFirst() {  // pan rows + fader row fill the strip
            v.widthAnchor.constraint(equalTo: strip.widthAnchor).isActive = true
        }
        return strip
    }

    private func makeCard(section: String, params: [ParameterDescriptor],
                          tone: ToneData) -> NSView {
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
            views.append(makeRow(d, tone: tone))
        }

        // The Pressure card hosts the live pitch/mute traces (relocated from
        // the retired header mini monitor), putting the playing feedback right
        // next to the parameters that shape it.
        if domain == .instrument, section == "Pressure" {
            let pitch = StripChartView(title: "Pitch", color: .systemBlue)
            pitch.heightAnchor.constraint(equalToConstant: 66).isActive = true
            let mute = StripChartView(title: "Mute", color: .systemPurple)
            mute.heightAnchor.constraint(equalToConstant: 66).isActive = true
            pitch.onOpen = { [weak self] in self?.onOpenMonitor?() }
            mute.onOpen = { [weak self] in self?.onOpenMonitor?() }
            pitchChart = pitch
            muteChart = mute
            views += [pitch, mute]
        }

        let inner = NSStackView(views: views)
        inner.orientation = .vertical
        inner.alignment = .leading
        // Rows keep their fixed heights; when the column equalization gives
        // the card extra height, equal spacing turns it into breathing room
        // between rows instead of a dead patch at the bottom.
        inner.distribution = .equalSpacing
        inner.spacing = 2
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

    @objc private func saveClicked() {
        onSave?()
    }

    @objc private func nameEdited() {
        guard tones[domain] != nil else { return }
        let name = nameField.stringValue
        tones[domain]?.name = name
        onRename?(domain, name)
    }
}
