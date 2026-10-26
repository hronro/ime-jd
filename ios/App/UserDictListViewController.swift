import UIKit
import UniformTypeIdentifiers

/// The phrase list: the user dictionary's file as a table, saved as it is
/// edited. Every row is written as typed — the screen validates nothing —
/// and the engine's verdict on each row, from the build that follows every
/// save, is its subtitle: a line the engine skips because it does not parse
/// (red), a duplicate it drops (grey), a phrase on a code a built-in word or
/// another row already uses (orange; it works, listed first). Order among
/// phrases on one code is file order, which is what reordering in edit mode
/// is for. The file travels: 导出… hands it to the share sheet as it is,
/// and a file from another device is imported through the Files picker and
/// appended as it is; the duplicates that may make are the engine's to flag
/// and the user's to remove, with 移除重复词条.
final class UserDictListViewController: UITableViewController, UISearchResultsUpdating {
    private enum Section: Int, CaseIterable {
        case settings
        case actions
        case phrases
    }

    private enum Action: Int, CaseIterable {
        case importFile
        case exportFile
        case removeDuplicates
    }

    private let store: UserDictStore
    /// The rows on screen, as indices into the store's rows: all of them,
    /// or the search hits.
    private var shown: [Int] = []
    private var filter = ""
    private var storeObserver: NSObjectProtocol?
    private let enableSwitch = UISwitch()

    init(store: UserDictStore = .shared) {
        self.store = store
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "用户自造词"
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.addPhrase() }),
            editButtonItem,
        ]
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "搜索词或编码"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false

        enableSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.store.isEnabled = self.enableSwitch.isOn
        }, for: .valueChanged)
        tableView.register(PhraseCell.self, forCellReuseIdentifier: PhraseCell.reuseID)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "switch")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "action")
        tableView.allowsSelectionDuringEditing = false

        storeObserver = NotificationCenter.default.addObserver(
            forName: UserDictStore.didChange, object: store, queue: .main
        ) { [weak self] _ in self?.refresh() }
        refresh()
    }

    // MARK: - Model

    private func refresh() {
        enableSwitch.isOn = store.isEnabled
        refreshShown()
        tableView.reloadData()
    }

    private func refreshShown() {
        let rows = store.rows
        if filter.isEmpty {
            shown = Array(rows.indices)
        } else {
            shown = rows.indices.filter {
                rows[$0].entry.value.localizedCaseInsensitiveContains(filter)
                    || rows[$0].entry.keys.localizedCaseInsensitiveContains(filter)
            }
        }
    }

    private func save(_ entries: [UserDictEntry]) {
        do {
            try store.save(entries)
        } catch {
            alert("无法保存", error.localizedDescription)
        }
    }

    private func alert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Add and edit

    private func addPhrase() {
        presentForm(title: "添加词条", entry: UserDictEntry(value: "", keys: "")) { [weak self] entry in
            guard let self else { return }
            self.save(self.store.entries + [entry])
        }
    }

    private func editPhrase(at index: Int) {
        presentForm(title: "编辑词条", entry: store.entries[index]) { [weak self] entry in
            guard let self else { return }
            var entries = self.store.entries
            guard entries.indices.contains(index) else { return }
            entries[index] = entry
            self.save(entries)
        }
    }

    /// Two fields; whatever is typed is saved as it is — the engine judges it.
    private func presentForm(title: String, entry: UserDictEntry, done: @escaping (UserDictEntry) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "词"
            field.text = entry.value
            field.clearButtonMode = .whileEditing
        }
        alert.addTextField { field in
            field.placeholder = "编码（a-z，1 到 \(UserDict.maxKeyLength) 个）"
            field.text = entry.keys
            field.keyboardType = .asciiCapable
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak alert] _ in
            let fields = alert?.textFields ?? []
            done(UserDictEntry(value: fields.first?.text ?? "", keys: fields.last?.text ?? ""))
        })
        present(alert, animated: true)
    }

    // MARK: - Import

    /// Pick a phrases file in Files. `.data` rather than `.plainText`: a
    /// text file that reached the device without its extension is typed as
    /// plain data and would be greyed out, and what a pick holds is checked
    /// afterwards anyway. The pick is a copy in this app's tmp directory.
    private func importFromFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.delegate = self
        picker.shouldShowFileExtensions = true
        present(picker, animated: true)
    }

    /// The file is read: append its rows as they are, the way a typed row is
    /// taken. The screen compares nothing; what that makes of the list is
    /// the engine's verdict, duplicates grey, for 移除重复词条 when the
    /// user wants. The list scrolls to the first appended row.
    private func append(importing imported: [UserDictEntry]) {
        let first = store.entries.count
        do {
            try store.saveIfBuildable(store.entries + imported)
        } catch {
            alert("无法导入", error.localizedDescription)
            return
        }
        if let row = shown.firstIndex(of: first) {
            tableView.scrollToRow(at: IndexPath(row: row, section: Section.phrases.rawValue), at: .top, animated: true)
        }
    }

    // MARK: - Export

    /// Share the phrases file itself: the sheet offers AirDrop, 存储到「文件」
    /// and whatever app takes a text file. The copy it is handed is removed
    /// once the sheet is done.
    private func exportFile(from cell: UITableViewCell?) {
        let url: URL
        do {
            url = try store.exportCopy()
        } catch {
            alert("无法导出", error.localizedDescription)
            return
        }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: url)
        }
        // On iPad the sheet is a popover: anchor it to the row.
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = cell ?? view
            popover.sourceRect = cell?.bounds ?? CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(sheet, animated: true)
    }

    // MARK: - Duplicates

    /// Delete the rows the engine flags as duplicates, after a confirmation
    /// that counts them and says what they repeat — the Mac window's
    /// 移除重复词条, in the same words.
    private func removeDuplicates() {
        let rows = store.duplicateRows
        guard !rows.isEmpty else { return }
        let ofRows = rows.filter {
            if case .duplicate(ofRow: .some) = store.problems[$0] { return true }
            return false
        }.count
        let alert = UIAlertController(
            title: "移除 \(rows.count) 条重复词条？",
            message: "\(ofRows) 条与前面的词条相同，\(rows.count - ofRows) 条与内置词相同；这些词条不会出现在候选中。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "移除", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                try self.store.removeDuplicates()
            } catch {
                self.alert("无法保存", error.localizedDescription)
            }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Search

    func updateSearchResults(for searchController: UISearchController) {
        filter = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        refreshShown()
        tableView.reloadData()
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .settings: return 1
        case .actions: return Action.allCases.count
        case .phrases: return shown.count
        case nil: return 0
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .settings:
            return store.statusText
        case .actions:
            return "导入其他设备上的键道导出的用户自造词（.txt），或任何同样格式的 UTF-8 文本文件：每行一条，词和编码之间用制表符分隔；"
                + "文件需先存入「文件」或 iCloud 云盘。导入的词条追加在列表末尾。"
                + "「导出」把这里的词条作为同样格式的文本文件分享出去：隔空投送、存储到「文件」或发给其他应用。"
                + "与前面的词条或内置词相同的词条算重复，不生效，「移除重复词条」会把它们一并删除。"
        case .phrases:
            if store.rows.isEmpty {
                return "尚无词条。轻点右上角的 + 添加：一个词和它的编码。与内置词同码时，自造词排在内置词之前。"
            }
            return filter.isEmpty
                ? "左滑删除。同一编码下的词按此处的顺序排列，编辑模式下拖动可调整。"
                : "搜索时不能拖动排序。"
        case nil:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) {
        case .phrases:
            let cell = tableView.dequeueReusableCell(withIdentifier: PhraseCell.reuseID, for: indexPath) as! PhraseCell
            let index = shown[indexPath.row]
            let problem = store.problems.indices.contains(index) ? store.problems[index] : nil
            cell.show(store.rows[index].entry, problem: problem)
            return cell
        case .actions:
            let cell = tableView.dequeueReusableCell(withIdentifier: "action", for: indexPath)
            var content = cell.defaultContentConfiguration()
            let enabled: Bool
            switch Action(rawValue: indexPath.row) {
            case .exportFile:
                content.text = "导出…"
                content.image = UIImage(systemName: "square.and.arrow.up")
                enabled = !store.rows.isEmpty
            case .removeDuplicates:
                content.text = "移除重复词条"
                content.image = UIImage(systemName: "trash")
                // Greyed out while the engine flags none — or has no notes,
                // the file having failed to build at all.
                enabled = !store.duplicateRows.isEmpty
            case .importFile, nil:
                content.text = "从文件导入…"
                content.image = UIImage(systemName: "square.and.arrow.down")
                enabled = true
            }
            content.textProperties.color = enabled ? .tintColor : .tertiaryLabel
            content.imageProperties.tintColor = enabled ? .tintColor : .tertiaryLabel
            cell.contentConfiguration = content
            cell.accessoryType = .none
            cell.isUserInteractionEnabled = enabled
            return cell
        case .settings, nil:
            let cell = tableView.dequeueReusableCell(withIdentifier: "switch", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = "启用用户自造词"
            cell.contentConfiguration = content
            cell.accessoryView = enableSwitch
            cell.selectionStyle = .none
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .phrases:
            editPhrase(at: shown[indexPath.row])
        case .actions:
            switch Action(rawValue: indexPath.row) {
            case .importFile: importFromFile()
            case .exportFile: exportFile(from: tableView.cellForRow(at: indexPath))
            case .removeDuplicates: removeDuplicates()
            case nil: break
            }
        case .settings, nil:
            break
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        Section(rawValue: indexPath.section) == .phrases
    }

    override func tableView(
        _ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, Section(rawValue: indexPath.section) == .phrases else { return }
        var entries = store.entries
        entries.remove(at: shown[indexPath.row])
        save(entries)
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        Section(rawValue: indexPath.section) == .phrases && filter.isEmpty
    }

    override func tableView(
        _ tableView: UITableView, targetIndexPathForMoveFromRowAt source: IndexPath,
        toProposedIndexPath proposed: IndexPath
    ) -> IndexPath {
        proposed.section == source.section ? proposed : source
    }

    override func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        guard source.section == destination.section, filter.isEmpty else { return }
        var entries = store.entries
        let moved = entries.remove(at: source.row)
        entries.insert(moved, at: destination.row)
        save(entries)
    }
}

extension UserDictListViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        // The copy is this app's to remove.
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = Result { try UserDictStore.entries(importedFrom: url) }
        // Whether the picker has already dismissed itself when this arrives
        // is the system's business; a presentation over one on its way out
        // would be refused.
        afterDismissal(of: controller) { [weak self] in
            guard let self else { return }
            switch outcome {
            case .success(let entries): self.append(importing: entries)
            case .failure(let error): self.alert("无法导入", error.localizedDescription)
            }
        }
    }

    private func afterDismissal(of controller: UIViewController, _ work: @escaping () -> Void) {
        if controller.isBeingDismissed, let coordinator = controller.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { _ in work() }
        } else if controller.presentingViewController != nil {
            controller.dismiss(animated: true, completion: work)
        } else {
            work()
        }
    }
}

/// The phrase on top; its code and the engine's verdict below, coloured by
/// the verdict.
private final class PhraseCell: UITableViewCell {
    static let reuseID = "phrase"

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ entry: UserDictEntry, problem: UserDictProblem?) {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = entry.value.isEmpty ? " " : entry.value
        content.secondaryText = problem.map { "\(entry.keys)  ·  \($0.text)" } ?? entry.keys
        content.textToSecondaryTextVerticalPadding = 4
        content.textProperties.color = (problem?.isInvalid == true || problem?.isDuplicate == true) ? .secondaryLabel : .label
        content.secondaryTextProperties.color = Self.color(for: problem)
        contentConfiguration = content
        accessoryType = .disclosureIndicator
    }

    private static func color(for problem: UserDictProblem?) -> UIColor {
        switch problem {
        case .invalid?: return .systemRed
        case .sharedCode?: return .systemOrange
        case .duplicate?, nil: return .secondaryLabel
        }
    }
}
