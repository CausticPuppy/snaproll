import AppKit
import AFrameKit

/// Sidebar: instrument/effect switcher plus the 80-slot tone list.
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onDomainChange: ((ToneSelect) -> Void)?
    var onSelectTone: ((ToneSelect, Int) -> Void)?

    private(set) var domain: ToneSelect = .instrument
    private var names: [ToneSelect: [String]] = [.instrument: [], .effect: []]
    private var selected: [ToneSelect: Int] = [.instrument: 0, .effect: 0]
    private var suppressSelectionCallback = false

    private let segmented = NSSegmentedControl(
        labels: ["Instruments", "Effects"], trackingMode: .selectOne,
        target: nil, action: nil)
    private let tableView = NSTableView()

    override func loadView() {
        segmented.selectedSegment = 0
        segmented.target = self
        segmented.action = #selector(domainChanged)
        segmented.segmentDistribution = .fillEqually

        let column = NSTableColumn(identifier: .init("tone"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowHeight = 24
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = false

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let stack = NSStackView(views: [segmented, scroll])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            segmented.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        view = container
    }

    // MARK: State input

    func setNames(_ list: [String], for sel: ToneSelect) {
        names[sel] = list
        if sel == domain { tableView.reloadData() }
        reselect()
    }

    func setSelected(num: Int, for sel: ToneSelect) {
        selected[sel] = num
        if sel == domain { reselect() }
    }

    func clear() {
        names = [.instrument: [], .effect: []]
        tableView.reloadData()
    }

    private func reselect() {
        guard let num = selected[domain], num < tableView.numberOfRows else { return }
        suppressSelectionCallback = true
        tableView.selectRowIndexes([num], byExtendingSelection: false)
        tableView.scrollRowToVisible(num)
        suppressSelectionCallback = false
    }

    // MARK: Actions

    @objc private func domainChanged() {
        domain = segmented.selectedSegment == 0 ? .instrument : .effect
        tableView.reloadData()
        reselect()
        onDomainChange?(domain)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        names[domain]?.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ToneCellView
            ?? ToneCellView(identifier: id)
        cell.configure(index: row, name: names[domain]?[row] ?? "")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback, tableView.selectedRow >= 0 else { return }
        selected[domain] = tableView.selectedRow
        onSelectTone?(domain, tableView.selectedRow)
    }
}

private final class ToneCellView: NSTableCellView {
    private let indexLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        indexLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        indexLabel.textColor = .tertiaryLabelColor
        indexLabel.alignment = .right
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [indexLabel, nameLabel])
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

    func configure(index: Int, name: String) {
        indexLabel.stringValue = String(format: "%02d", index + 1)
        nameLabel.stringValue = name.isEmpty ? "—" : name
    }
}
