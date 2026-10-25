import AppKit

/// The user-dictionary window: a table over the phrases file, saved as it is
/// edited.
///
/// The table *is* the file. Rows are loaded from `用户自造词.txt` (comments
/// and blank lines skipped), and after every edit, addition, deletion or
/// drag-reorder every row is written back as it is, in table order, and the
/// engine's dictionary rebuilt (UserDictStore.save). The window validates
/// nothing itself: libjd's build notes, mapped onto the rows by line after
/// every save, are the status column. A row the engine skips because it
/// does not parse — empty or malformed keys, an over-long value — is shown
/// in red with the engine's reason; a row it drops as a duplicate (the same
/// phrase on the same code as an earlier row, or as a built-in word) in
/// grey; a row whose code is already taken — by a built-in word, by another
/// row, or both — in orange: it works, listed first, and the flag is a
/// warning only. The 移除重复词条 button offers to delete the duplicates,
/// counted and explained — or says so while the file cannot be loaded at
/// all, when there are no notes to act on.
///
/// Order matters only among phrases on the same code — they appear in file
/// order — which is what dragging rows is for.
///
/// The window lives in the IME process: InputMethodKit does serve text
/// fields in the IME's own process (verified on macOS 26), so phrases are
/// typed here with 键道 like anywhere else.
final class UserDictWindowController: NSWindowController, NSWindowDelegate {
    static let shared = UserDictWindowController(store: .shared)

    private struct Row {
        var entry: UserDictEntry
        /// The row's 1-based line in the file; nil only for a row just added
        /// and not yet written.
        var fileLine: Int?
        var problem: Problem?
    }

    /// The status column's verdicts: the mapping and its words are shared
    /// with the iOS phrase list (bindings/swift/UserDictProblem.swift).
    private typealias Problem = UserDictProblem

    private enum ColumnID {
        static let value = NSUserInterfaceItemIdentifier("value")
        static let keys = NSUserInterfaceItemIdentifier("keys")
        static let status = NSUserInterfaceItemIdentifier("status")
    }

    private static let rowPasteboardType = NSPasteboard.PasteboardType("com.hronro.ime-jd.user-dict-row")

    let store: UserDictStore
    private var rows: [Row] = []
    /// The rows on screen, as indices into `rows`: all of them, or the
    /// search hits.
    private var shown: [Int] = []
    private var filter = ""
    /// What the last save wrote (or the text last loaded), so a file change
    /// that reads back identical — our own write — does not reload the table.
    private var lastKnownText: String?
    /// Set around the store's `save`, whose notification arrives
    /// synchronously, in the middle of a model change that the caller is
    /// about to redraw; redrawing from inside it crashed the IME once (the
    /// row count had changed under the table).
    private var isSaving = false

    private let tableView = UserDictTableView()
    private let addRemove = NSSegmentedControl(
        images: [
            NSImage(named: NSImage.addTemplateName)!,
            NSImage(named: NSImage.removeTemplateName)!,
        ],
        trackingMode: .momentary, target: nil, action: nil
    )
    private let enableCheckbox = NSButton(checkboxWithTitle: "启用用户自造词", target: nil, action: nil)
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private var storeObserver: NSObjectProtocol?

    // MARK: - Setup

    init(store: UserDictStore) {
        self.store = store
        let window = UserDictWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "用户自造词"
        window.minSize = NSSize(width: 480, height: 300)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("JdUserDictWindow")
        buildContent(in: window)
        storeObserver = NotificationCenter.default.addObserver(
            forName: UserDictStore.didChange, object: store, queue: .main
        ) { [weak self] _ in
            self?.storeDidChange()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    private func buildContent(in window: NSWindow) {
        let content = NSView()
        window.contentView = content

        enableCheckbox.target = self
        enableCheckbox.action = #selector(toggleEnabled(_:))

        searchField.placeholderString = "搜索词或编码"
        searchField.target = self
        searchField.action = #selector(filterChanged(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        enableCheckbox.setContentHuggingPriority(.required, for: .horizontal)
        let top = NSStackView(views: [enableCheckbox, spacer, searchField])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.distribution = .fill
        top.setContentHuggingPriority(.required, for: .vertical)

        // Table.
        let valueColumn = NSTableColumn(identifier: ColumnID.value)
        valueColumn.title = "词"
        valueColumn.width = 220
        valueColumn.minWidth = 120
        let keysColumn = NSTableColumn(identifier: ColumnID.keys)
        keysColumn.title = "编码"
        keysColumn.width = 110
        keysColumn.minWidth = 70
        let statusColumn = NSTableColumn(identifier: ColumnID.status)
        statusColumn.title = "状态"
        statusColumn.width = 220
        statusColumn.minWidth = 120
        for column in [valueColumn, keysColumn, statusColumn] {
            column.isEditable = column.identifier != ColumnID.status
            tableView.addTableColumn(column)
        }
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = false
        tableView.rowHeight = 24
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([Self.rowPasteboardType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.onDelete = { [weak self] in self?.removeSelectedRows(nil) }
        tableView.onReturn = { [weak self] in self?.editSelectedRow() }

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)

        // Bottom bar.
        addRemove.target = self
        addRemove.action = #selector(addRemoveClicked(_:))
        addRemove.segmentStyle = .smallSquare
        addRemove.setToolTip("添加词条", forSegment: 0)
        addRemove.setToolTip("删除选中的词条", forSegment: 1)

        let removeButton = NSButton(title: "移除重复词条", target: self, action: #selector(removeDuplicates(_:)))
        let editorButton = NSButton(title: "用文本编辑器打开", target: self, action: #selector(openInEditor(_:)))
        for button in [removeButton, editorButton] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
        }

        statusLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bottom = NSStackView(views: [addRemove, removeButton, editorButton, statusLabel])
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.distribution = .fill
        bottom.spacing = 8
        bottom.setContentHuggingPriority(.required, for: .vertical)

        let stack = NSStackView(views: [top, scroll, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        updateRemoveButton()
    }

    // MARK: - Showing

    /// Open (or bring forward) the window. A fresh open reloads from the
    /// file; an already-open window is left as it is.
    func show() {
        if window?.isVisible != true {
            loadRows(from: currentFileText())
        }
        enableCheckbox.state = store.isEnabled ? .on : .off
        updateStatus()
        // We are an accessory app; without this the window opens behind the
        // frontmost app's windows.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Ends a cell edit in progress, which saves it; nothing is ever
        // pending.
        sender.makeFirstResponder(nil)
        return true
    }

    // MARK: - Model

    private func currentFileText() -> String? {
        (try? UserDictFile.read(at: store.fileURL)) ?? nil
    }

    func loadRows(from text: String?) {
        lastKnownText = text
        rows = UserDictFile.parse(text ?? "").map { Row(entry: $0.entry, fileLine: $0.line, problem: nil) }
        recomputeProblems()
        refreshShown()
        tableView.reloadData()
        updateRemoveButton()
    }

    /// The table's phrases, in table order, pending rows included.
    var entries: [UserDictEntry] {
        rows.map(\.entry)
    }

    /// What the status column says for a row, nil when nothing is wrong.
    func statusText(forRow index: Int) -> String? {
        rows[index].problem?.text
    }

    /// Write every row as it is, in table order, and re-derive each row's
    /// line; the engine, not the window, decides what is valid. Callers that
    /// may interrupt a cell edit end it first (the actions make the table
    /// first responder); this runs inside end-editing too, where the table
    /// may be handing the edit to the next cell, so it never touches the
    /// responder chain itself.
    private func saveRows() {
        for index in rows.indices {
            rows[index].fileLine = UserDictFile.line(ofEntryAt: index)
        }
        let entries = rows.map(\.entry)
        lastKnownText = UserDictFile.serialize(entries)
        isSaving = true
        defer { isSaving = false }
        do {
            try store.save(entries)
        } catch {
            NSLog("JdIME: user dict: save failed: %@", String(describing: error))
            let alert = NSAlert()
            alert.messageText = "无法保存用户自造词"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
        recomputeProblems()
    }

    /// libjd's notes about the file the current dictionary was built from,
    /// mapped onto rows by line: why a skipped row does not parse, what a
    /// dropped row repeats, and whose code a kept row shares.
    private func recomputeProblems() {
        let problems = UserDictProblem.forRows(
            lines: rows.map(\.fileLine),
            report: store.lastError == nil ? store.report : nil
        )
        for index in rows.indices {
            rows[index].problem = problems[index]
        }
    }

    private func refreshShown() {
        if filter.isEmpty {
            shown = Array(rows.indices)
        } else {
            shown = rows.indices.filter {
                rows[$0].entry.value.localizedCaseInsensitiveContains(filter)
                    || rows[$0].entry.keys.localizedCaseInsensitiveContains(filter)
            }
        }
    }

    private func updateStatus() {
        var parts = ["共 \(rows.count) 条"]
        let invalid = rows.filter { $0.problem?.isInvalid == true }.count
        if invalid > 0 { parts.append("\(invalid) 条无效") }
        let duplicates = rows.filter { $0.problem?.isDuplicate == true }.count
        if duplicates > 0 { parts.append("\(duplicates) 条重复") }
        let shared = rows.filter { $0.problem?.isSharedCode == true }.count
        if shared > 0 { parts.append("\(shared) 条同码") }
        if let error = store.lastError { parts.append(error.message) }
        if !store.isEnabled { parts.append("已停用") }
        statusLabel.stringValue = parts.joined(separator: "，")
        statusLabel.toolTip = statusLabel.stringValue
    }

    /// After a change to `rows`: save, then redraw everything. `shown` is
    /// brought in line with `rows` first, so nothing between here and the
    /// redraw can index the table against stale rows.
    private func commitRows() {
        refreshShown()
        saveRows()
        tableView.reloadData()
        updateStatus()
        updateRemoveButton()
    }

    private func updateRemoveButton() {
        addRemove.setEnabled(tableView.selectedRow >= 0, forSegment: 1)
    }

    private func storeDidChange() {
        // Our own save: the caller redraws once it is done.
        guard !isSaving else { return }
        enableCheckbox.state = store.isEnabled ? .on : .off
        guard window?.isVisible == true else { return }
        let text = currentFileText()
        if text != lastKnownText {
            // Changed from outside — a text editor, most likely.
            loadRows(from: text)
        } else {
            recomputeProblems()
            reloadStatusColumn()
        }
        updateStatus()
    }

    private func reloadStatusColumn() {
        guard tableView.numberOfRows == shown.count else {
            // The row count moved; only a full reload is safe.
            tableView.reloadData()
            return
        }
        let column = tableView.column(withIdentifier: ColumnID.status)
        guard column >= 0, !shown.isEmpty else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integersIn: 0..<shown.count), columnIndexes: IndexSet(integer: column)
        )
    }

    // MARK: - Actions

    @objc private func toggleEnabled(_ sender: NSButton) {
        store.isEnabled = sender.state == .on
        updateStatus()
    }

    @objc private func filterChanged(_ sender: NSSearchField) {
        window?.makeFirstResponder(sender)
        filter = sender.stringValue.trimmingCharacters(in: .whitespaces)
        refreshShown()
        tableView.reloadData()
        updateRemoveButton()
    }

    @objc private func addRemoveClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            addRow(nil)
        } else {
            removeSelectedRows(nil)
        }
    }

    /// A new, empty row below the selection (or at the end), with its 词
    /// cell already being edited. It is written, like every row, when the
    /// edit ends; the engine then says what it thinks of it.
    @objc private func addRow(_ sender: Any?) {
        window?.makeFirstResponder(tableView)
        guard rows.count < UserDict.maxEntries else {
            let alert = NSAlert()
            alert.messageText = "词条数量已达上限"
            alert.informativeText = "用户自造词最多 \(UserDict.maxEntries) 条。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        // Below the selection, or at the end; the search filter is cleared so
        // the new row is on screen.
        let insertAt = tableView.selectedRowIndexes.last.map { shown[$0] + 1 } ?? rows.count
        if !filter.isEmpty {
            searchField.stringValue = ""
            filter = ""
        }
        rows.insert(Row(entry: UserDictEntry(value: "", keys: ""), fileLine: nil, problem: nil), at: insertAt)
        refreshShown()
        tableView.reloadData()
        updateStatus()
        tableView.selectRowIndexes(IndexSet(integer: insertAt), byExtendingSelection: false)
        tableView.scrollRowToVisible(insertAt)
        tableView.editColumn(tableView.column(withIdentifier: ColumnID.value), row: insertAt, with: nil, select: true)
        updateRemoveButton()
    }

    @objc private func removeSelectedRows(_ sender: Any?) {
        window?.makeFirstResponder(tableView)
        let selected = tableView.selectedRowIndexes.map { shown[$0] }
        guard !selected.isEmpty else { return }
        if selected.count > 1 {
            let alert = NSAlert()
            alert.messageText = "删除选中的 \(selected.count) 条词条？"
            alert.informativeText = "删除后立即生效，无法撤销。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "删除")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        remove(rowsAt: selected)
    }

    func remove(rowsAt indices: [Int]) {
        for index in indices.sorted(by: >) {
            rows.remove(at: index)
        }
        tableView.deselectAll(nil)
        commitRows()
    }

    private func editSelectedRow() {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        tableView.editColumn(tableView.column(withIdentifier: ColumnID.value), row: row, with: nil, select: true)
    }

    /// What 移除重复词条 has to say, apart from how it says it: the rows libjd
    /// drops as duplicates and the rows whose code is already taken — both
    /// flagged in the table already — summed up, with the rows it skipped
    /// as unparsable mentioned; or that nothing can be done, because
    /// the file could not be loaded at all and so there are no notes.
    enum DuplicateCheck: Equatable {
        case unavailable(reason: String)
        case clean(invalid: Int)
        case found(duplicates: [Int], shared: [Int], invalid: Int)
    }

    func duplicateCheck() -> DuplicateCheck {
        if let error = store.lastError {
            return .unavailable(reason: error.message)
        }
        let invalid = rows.filter { $0.problem?.isInvalid == true }.count
        let duplicates = rows.indices.filter { rows[$0].problem?.isDuplicate == true }
        let shared = rows.indices.filter { rows[$0].problem?.isSharedCode == true }
        if duplicates.isEmpty, shared.isEmpty {
            return .clean(invalid: invalid)
        }
        return .found(duplicates: duplicates, shared: shared, invalid: invalid)
    }

    private func invalidNote(_ invalid: Int) -> String {
        "另有 \(invalid) 条无效的词条（标红），输入法已跳过。"
    }

    /// Behind the 移除重复词条 button: the offer to delete the rows libjd
    /// drops as duplicates, counted and explained. The same-code rows, which
    /// stay, and the skipped rows are mentioned, and 选中查看 selects every
    /// flagged row to look at instead. While the file cannot be loaded at
    /// all it says so: the engine never built this version of the file, so
    /// there are no notes to act on.
    @objc private func removeDuplicates(_ sender: Any?) {
        window?.makeFirstResponder(tableView)
        switch duplicateCheck() {
        case .unavailable(let reason):
            let text = "用户自造词文件无法读入：\(reason)。请用文本编辑器修正文件；文件可读后，状态列才会标出无效、重复与同码的词条。"
            let alert = NSAlert()
            alert.messageText = "无法移除重复词条"
            alert.informativeText = text
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.addButton(withTitle: "用文本编辑器打开")
            if alert.runModal() == .alertSecondButtonReturn {
                openInEditor(nil)
            }
        case .clean(let invalid):
            var text = "与前面某条词条完全相同、或与内置词库中同一编码下的词相同的词条，算重复，不会生效。"
            if invalid > 0 {
                text += "\n" + invalidNote(invalid)
            }
            let alert = NSAlert()
            alert.messageText = "没有重复词条"
            alert.informativeText = text
            alert.addButton(withTitle: "好")
            alert.runModal()
        case .found(let duplicates, let shared, let invalid):
            offerRemoval(duplicates: duplicates, shared: shared, invalid: invalid)
        }
    }

    /// The counts and what they mean, with 移除 for the duplicates when
    /// there are any, and 选中查看 for every flagged row.
    private func offerRemoval(duplicates: [Int], shared: [Int], invalid: Int) {
        var details: [String] = []
        if !duplicates.isEmpty {
            let ofRows = duplicates.filter {
                if case .duplicate(ofRow: .some) = rows[$0].problem { return true }
                return false
            }.count
            details.append(
                "重复：\(ofRows) 条与前面的词条相同，\(duplicates.count - ofRows) 条与内置词库相同；这些词条不会出现在候选中。"
            )
        }
        if !shared.isEmpty {
            details.append(
                "同码（保留）：\(shared.count) 条词条的编码已有内置词或其他自造词；这些词条仍然生效，并排在内置词之前，多条自造词同码时按表中顺序排列。"
            )
        }
        if invalid > 0 {
            details.append(invalidNote(invalid))
        }
        let alert = NSAlert()
        alert.messageText = duplicates.isEmpty ? "没有重复词条" : "移除 \(duplicates.count) 条重复词条？"
        alert.informativeText = details.joined(separator: "\n")
        // 选中查看 is the second button either way.
        alert.addButton(withTitle: duplicates.isEmpty ? "好" : "移除")
        alert.addButton(withTitle: "选中查看")
        if !duplicates.isEmpty {
            alert.addButton(withTitle: "取消")
        }

        let response = alert.runModal()
        if !duplicates.isEmpty, response == .alertFirstButtonReturn {
            remove(rowsAt: duplicates)
        } else if response == .alertSecondButtonReturn {
            if !filter.isEmpty {
                searchField.stringValue = ""
                filter = ""
                refreshShown()
                tableView.reloadData()
            }
            let flagged = IndexSet(duplicates + shared)
            tableView.selectRowIndexes(flagged, byExtendingSelection: false)
            if let first = flagged.first {
                tableView.scrollRowToVisible(first)
            }
        }
    }

    /// The same file, in whatever app handles `.txt`. The store watches the
    /// file, so a save there shows up here and in the engine.
    @objc private func openInEditor(_ sender: Any?) {
        window?.makeFirstResponder(tableView)
        if !FileManager.default.fileExists(atPath: store.fileURL.path) {
            try? UserDictFile.write(UserDictFile.serialize([]), to: store.fileURL)
        }
        NSWorkspace.shared.open(store.fileURL)
    }
}

// MARK: - Table data

extension UserDictWindowController: NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        shown.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButton()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < shown.count, shown[row] < rows.count else { return nil }
        let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView
            ?? makeCell(for: column)
        let model = rows[shown[row]]
        guard let field = cell.textField else { return cell }
        switch column.identifier {
        case ColumnID.value:
            field.stringValue = model.entry.value
        case ColumnID.keys:
            field.stringValue = model.entry.keys
        default:
            field.stringValue = model.problem?.text ?? ""
            switch model.problem {
            case .invalid?: field.textColor = .systemRed
            case .sharedCode?: field.textColor = .systemOrange
            default: field.textColor = .secondaryLabelColor
            }
        }
        return cell
    }

    private func makeCell(for column: NSTableColumn) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = column.identifier
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        switch column.identifier {
        case ColumnID.value:
            field.isEditable = true
            field.font = NSFont.systemFont(ofSize: 14)
            field.placeholderString = "词"
        case ColumnID.keys:
            field.isEditable = true
            field.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            field.placeholderString = "编码"
        default:
            field.isEditable = false
            field.isSelectable = false
            field.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            field.textColor = .secondaryLabelColor
        }
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// A cell edit ended: trim the way libjd will, store it, save if it
    /// changed anything. Only the status column is redrawn — the edited cell
    /// already shows the text, and redrawing the row would cut short the
    /// Tab-to-next-cell the table is in the middle of.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let viewRow = tableView.row(for: field)
        let viewColumn = tableView.column(for: field)
        guard viewRow >= 0, viewColumn >= 0, viewRow < shown.count else { return }
        let index = shown[viewRow]
        let text = field.stringValue.trimmingCharacters(in: UserDictFile.fieldTrim)
        field.stringValue = text
        var entry = rows[index].entry
        switch tableView.tableColumns[viewColumn].identifier {
        case ColumnID.value: entry.value = text
        case ColumnID.keys: entry.keys = text
        default: return
        }
        // A row never written yet is written even when the edit changed
        // nothing, so the engine's verdict on it shows.
        guard entry != rows[index].entry || rows[index].fileLine == nil else { return }
        rows[index].entry = entry
        saveRows()
        reloadStatusColumn()
        updateStatus()
    }

    // MARK: Drag to reorder (file order; disabled while searching)

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard filter.isEmpty else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(shown[row]), forType: Self.rowPasteboardType)
        return item
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo,
        proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard filter.isEmpty, info.draggingSource as? NSTableView === tableView else { return [] }
        if dropOperation == .on {
            tableView.setDropRow(row, dropOperation: .above)
        }
        return .move
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
        row: Int, dropOperation: NSTableView.DropOperation
    ) -> Bool {
        var sources = IndexSet()
        info.enumerateDraggingItems(options: [], for: tableView, classes: [NSPasteboardItem.self], searchOptions: [:]) {
            item, _, _ in
            if let text = (item.item as? NSPasteboardItem)?.string(forType: Self.rowPasteboardType),
               let index = Int(text) {
                sources.insert(index)
            }
        }
        guard !sources.isEmpty else { return false }
        move(rowsAt: sources, above: row)
        return true
    }

    /// Move `sources` so they sit, in their current order, just above the
    /// row that is currently at `target` (`rows.count` means the end).
    func move(rowsAt sources: IndexSet, above target: Int) {
        let moving = sources.map { rows[$0] }
        let insertAt = target - sources.filter { $0 < target }.count
        for index in sources.sorted(by: >) {
            rows.remove(at: index)
        }
        rows.insert(contentsOf: moving, at: insertAt)
        commitRows()
        tableView.selectRowIndexes(IndexSet(integersIn: insertAt..<insertAt + moving.count), byExtendingSelection: false)
        updateRemoveButton()
    }
}

/// Delete and Return on a selected row, when no cell is being edited.
final class UserDictTableView: NSTableView {
    var onDelete: (() -> Void)?
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if selectedRow >= 0, window?.firstResponder === self {
            switch event.keyCode {
            case KeyCode.delete, 117: // 117: forward delete
                onDelete?()
                return
            case KeyCode.return, KeyCode.enter:
                onReturn?()
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }
}

/// An accessory app has no menu bar, so ⌘W has nobody to close the window.
final class UserDictWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
