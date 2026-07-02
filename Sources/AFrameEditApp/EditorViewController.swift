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

    // MARK: Building

    private func rebuild() {
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

        var views: [NSView] = [title]
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
        inner.setCustomSpacing(8, after: title)
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
        for v in views.dropFirst() {
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
