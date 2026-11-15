import UIKit

/// 编码反查: which codes type a word. The word goes into the field at the top
/// — typed, with 键道 or any keyboard, or pasted — and 查询, or the
/// keyboard's search key, lists its codes below, shortest first: libjd's
/// `jd_lookup_codes` over the built-in tables and, while the switch is on,
/// the user dictionary, the dictionaries the keyboard types with. A code on
/// which the word is not the first candidate says which one it is; a code
/// from the user dictionary says so. The wording is `CodeLookupReport`'s,
/// shared with the macOS window.
final class CodeLookupViewController: UIViewController, UITableViewDataSource, UITextFieldDelegate {
    private let store: UserDictStore
    /// A word to look up as the page opens (the `-lookup` QA launch arg).
    private let initialQuery: String?
    private let field = UITextField()
    private let lookUpButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    /// Shown instead of the list when the word has no codes.
    private let notFoundLabel = UILabel()
    private var report: CodeLookupReport?

    init(store: UserDictStore = .shared, query: String? = nil) {
        self.store = store
        initialQuery = query
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "编码反查"
        view.backgroundColor = .systemGroupedBackground

        field.placeholder = "输入或粘贴要查询的词"
        field.borderStyle = .roundedRect
        field.backgroundColor = .secondarySystemGroupedBackground
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .search
        field.enablesReturnKeyAutomatically = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.delegate = self
        field.addAction(UIAction { [weak self] _ in self?.updateButton() }, for: .editingChanged)

        var button = UIButton.Configuration.filled()
        button.title = "查询"
        button.cornerStyle = .medium
        lookUpButton.configuration = button
        lookUpButton.addAction(UIAction { [weak self] _ in self?.lookUp() }, for: .primaryActionTriggered)
        lookUpButton.setContentHuggingPriority(.required, for: .horizontal)
        lookUpButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let inputRow = UIStackView(arrangedSubviews: [field, lookUpButton])
        inputRow.axis = .horizontal
        inputRow.spacing = 8
        inputRow.alignment = .fill
        inputRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(inputRow)

        tableView.dataSource = self
        tableView.backgroundColor = .clear
        tableView.allowsSelection = false
        tableView.keyboardDismissMode = .onDrag
        // Cells line up with the field above, on iPad too.
        tableView.cellLayoutMarginsFollowReadableWidth = true
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "code")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        notFoundLabel.numberOfLines = 0
        notFoundLabel.textAlignment = .center
        notFoundLabel.adjustsFontForContentSizeCategory = true
        notFoundLabel.translatesAutoresizingMaskIntoConstraints = false
        let notFound = UIView()
        notFound.addSubview(notFoundLabel)
        tableView.backgroundView = notFound

        let guide = view.readableContentGuide
        NSLayoutConstraint.activate([
            inputRow.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            inputRow.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            inputRow.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            inputRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            tableView.topAnchor.constraint(equalTo: inputRow.bottomAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            notFoundLabel.topAnchor.constraint(equalTo: notFound.safeAreaLayoutGuide.topAnchor, constant: 32),
            notFoundLabel.leadingAnchor.constraint(equalTo: notFound.readableContentGuide.leadingAnchor, constant: 16),
            notFoundLabel.trailingAnchor.constraint(equalTo: notFound.readableContentGuide.trailingAnchor, constant: -16),
        ])

        if let initialQuery {
            field.text = initialQuery
            lookUp()
        }
        updateButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Ready to type or paste into, unless the page opened on a result.
        if report == nil {
            field.becomeFirstResponder()
        }
    }

    // MARK: - Looking up

    private var query: String {
        CodeLookupReport.query(from: field.text ?? "")
    }

    private func updateButton() {
        lookUpButton.isEnabled = !query.isEmpty
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        lookUp()
        return false
    }

    private func lookUp() {
        let query = query
        guard !query.isEmpty else { return }
        // The keyboard would cover the codes.
        field.resignFirstResponder()
        // A fresh engine over what the keyboard types with right now: the
        // user dictionary only while it is switched on. Cheap — one
        // allocation and a validation pass over the user's phrases — and it
        // is gone when this returns; the codes are plain strings.
        let codes = Engine(userDict: store.activeDictionary).lookupCodes(query)
        report = CodeLookupReport(query: query, codes: codes, userDictEnabled: store.isEnabled)
        showReport()
    }

    private func showReport() {
        if let report, !report.found {
            // Both paragraphs need a style of their own: a part with none
            // gets the label's tail truncation and stops at one line.
            let title = NSMutableParagraphStyle()
            title.alignment = .center
            title.paragraphSpacing = 6
            let message = NSMutableParagraphStyle()
            message.alignment = .center
            let text = NSMutableAttributedString(
                string: report.title,
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .headline),
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: title,
                ]
            )
            text.append(NSAttributedString(
                string: "\n" + (report.message ?? ""),
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .subheadline),
                    .foregroundColor: UIColor.secondaryLabel,
                    .paragraphStyle: message,
                ]
            ))
            notFoundLabel.attributedText = text
            notFoundLabel.isHidden = false
        } else {
            notFoundLabel.attributedText = nil
            notFoundLabel.isHidden = true
        }
        tableView.reloadData()
    }

    // MARK: - The list

    func numberOfSections(in tableView: UITableView) -> Int {
        report?.found == true ? 1 : 0
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        report?.lines.count ?? 0
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        report?.title
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "code", for: indexPath)
        let line = report?.lines[indexPath.row]
        var content = UIListContentConfiguration.valueCell()
        content.text = line?.keys
        content.textProperties.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular
        )
        content.secondaryText = line?.note
        cell.contentConfiguration = content
        return cell
    }
}
