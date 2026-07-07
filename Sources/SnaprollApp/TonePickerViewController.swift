import AppKit
import AFrameKit

/// Popover content for browsing and selecting a tone slot within one domain:
/// a filter field over a scrollable list of the (up to 80) slots. Reports the
/// chosen zero-based slot via `onSelect`; the owner shows/dismisses the popover.
final class TonePickerViewController: NSViewController {
    var onSelect: ((Int) -> Void)?

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private var names: [String] = []
    private var selectedSlot = 0
    // The current filter view: table row -> original zero-based slot index.
    private var filtered: [Int] = []

    override func loadView() {
        searchField.placeholderString = "Filter"
        searchField.target = self
        searchField.action = #selector(searchSubmitted)
        searchField.sendsSearchStringImmediately = false
        searchField.delegate = self

        let column = NSTableColumn(identifier: .init("tone"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = 24
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true
        tableView.target = self
        tableView.action = #selector(rowClicked)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let stack = NSStackView(views: [searchField, scroll])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        preferredContentSize = NSSize(width: 260, height: 340)
    }

    /// Populates the list for a domain and highlights the current slot.
    func configure(names: [String], selected: Int, noun: String) {
        self.names = names
        self.selectedSlot = selected
        searchField.placeholderString = "Filter \(noun)"
        searchField.stringValue = ""
        applyFilter()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Focus the filter for immediate type-to-search, and reveal the current
        // slot so the list opens where the user already is.
        view.window?.makeFirstResponder(searchField)
        if let row = filtered.firstIndex(of: selectedSlot) {
            tableView.scrollRowToVisible(row)
        }
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = query.isEmpty
            ? Array(names.indices)
            : names.indices.filter { names[$0].lowercased().contains(query) }
        tableView.reloadData()
        if let row = filtered.firstIndex(of: selectedSlot) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
    }

    /// Return in the filter picks the highlighted row, else the first match.
    @objc private func searchSubmitted() {
        let row = tableView.selectedRow >= 0 ? tableView.selectedRow : (filtered.isEmpty ? -1 : 0)
        guard filtered.indices.contains(row) else { return }
        onSelect?(filtered[row])
    }

    @objc private func rowClicked() {
        guard filtered.indices.contains(tableView.clickedRow) else { return }
        onSelect?(filtered[tableView.clickedRow])
    }
}

extension TonePickerViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        applyFilter()
    }
}

extension TonePickerViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ToneSlotCell
            ?? ToneSlotCell(identifier: id)
        let slot = filtered[row]
        cell.configure(index: slot, name: names[slot], isCurrent: slot == selectedSlot)
        return cell
    }
}

private final class ToneSlotCell: NSTableCellView {
    private let indexLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let checkView = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        indexLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        indexLabel.textColor = .tertiaryLabelColor
        indexLabel.alignment = .right
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        checkView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Current tone")
        checkView.contentTintColor = .controlAccentColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [indexLabel, nameLabel, spacer, checkView])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            indexLabel.widthAnchor.constraint(equalToConstant: 22),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(index: Int, name: String, isCurrent: Bool) {
        indexLabel.stringValue = String(format: "%02d", index + 1)
        nameLabel.stringValue = name.isEmpty ? "—" : name
        nameLabel.textColor = name.isEmpty ? .tertiaryLabelColor : .labelColor
        checkView.isHidden = !isCurrent
    }
}
