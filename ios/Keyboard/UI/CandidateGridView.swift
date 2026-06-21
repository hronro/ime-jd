import UIKit

/// The expanded candidate list: a scrollable wrapping grid of ALL loaded
/// candidates, shown when the user taps the bar's expand chevron. Covers the keys.
final class CandidateGridView: UIView, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {
    var onSelect: ((Int) -> Void)?
    var onNeedMore: (() -> Void)?
    var onClose: (() -> Void)?

    private let collection: UICollectionView
    private let closeButton = ActionButton(type: .system)
    private let topSeparator = UIView()
    private var items: [Candidate] = []
    private var theme: KeyboardTheme

    init(theme: KeyboardTheme) {
        self.theme = theme
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        self.collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)
        build()
        apply(theme: theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        closeButton.setTitle("▴", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 18)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.onTap { [weak self] in self?.onClose?() }

        topSeparator.translatesAutoresizingMaskIntoConstraints = false

        collection.dataSource = self
        collection.delegate = self
        collection.backgroundColor = .clear
        collection.register(GridCell.self, forCellWithReuseIdentifier: "c")
        collection.translatesAutoresizingMaskIntoConstraints = false

        addSubview(closeButton)
        addSubview(topSeparator)
        addSubview(collection)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: topAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: CandidateBarView.height),

            topSeparator.topAnchor.constraint(equalTo: closeButton.bottomAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            topSeparator.heightAnchor.constraint(equalToConstant: 0.5),

            collection.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            collection.leadingAnchor.constraint(equalTo: leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func apply(theme: KeyboardTheme) {
        self.theme = theme
        backgroundColor = theme.keyboardBackground
        closeButton.setTitleColor(theme.candidateText, for: .normal)
        topSeparator.backgroundColor = theme.separator
        collection.reloadData()
    }

    func setItems(_ items: [Candidate]) {
        self.items = items
        collection.reloadData()
    }

    func append(_ new: [Candidate]) {
        guard !new.isEmpty else { return }
        items.append(contentsOf: new)
        collection.reloadData()
    }

    // MARK: - Data source / delegate

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection s: Int) -> Int { items.count }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: "c", for: ip) as! GridCell
        cell.label.attributedText = CandidateBarView.title(items[ip.item], theme: theme)
        cell.separator.backgroundColor = theme.separator
        return cell
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        onSelect?(ip.item)
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt ip: IndexPath) -> CGSize {
        let text = CandidateBarView.title(items[ip.item], theme: theme)
        let w = ceil(text.size().width) + 28
        return CGSize(width: min(w, cv.bounds.width), height: 46)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let nearBottom = scrollView.contentOffset.y + scrollView.bounds.height * 1.5 >= scrollView.contentSize.height
        if nearBottom { onNeedMore?() }
    }

    private final class GridCell: UICollectionViewCell {
        let label = UILabel()
        let separator = UIView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            separator.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(label)
            contentView.addSubview(separator)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
                separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                separator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                separator.heightAnchor.constraint(equalToConstant: 0.5),
            ])
        }
        required init?(coder: NSCoder) { fatalError() }
    }
}
