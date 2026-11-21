import UIKit

/// The always-visible candidate strip: the in-flight code on the left, a
/// horizontally scrolling row of candidates, and an expand chevron on the right.
/// A dumb renderer — the owner supplies items and handles selection / lazy loading.
///
/// The strip changes on every keystroke, so it is built for that: candidates are
/// measured once (`TitleSizes`), laid out by arithmetic rather than Auto Layout,
/// and drawn into a small pool of reused cells that only covers what is on screen
/// and half a screen to either side. It used to rebuild a button and a separator per
/// loaded candidate (16 a page) in a stack view on every keystroke, which took
/// ~28 ms of the main thread per key on an iPhone 16 Pro Max.
final class CandidateBarView: UIView, UIScrollViewDelegate {
    /// 54 rather than the English keyboard's 44: closer to the system Chinese
    /// keyboard's taller bar, and — with the key plane's top margin — enough
    /// headroom for the key-press callout to keep (nearly) its full system
    /// proportions on the top key row (the balloon cannot rise above the
    /// keyboard's own surface, see `KeyPopupView`).
    static let height: CGFloat = 54

    var onSelect: ((Int) -> Void)?
    var onExpand: (() -> Void)?
    var onNeedMore: (() -> Void)?

    private let composingLabel = UILabel()
    private let scroll = UIScrollView()
    private let expandButton = ActionButton(type: .system)
    private let topSeparator = UIView()
    private var theme: KeyboardTheme

    /// The loaded candidates' titles, and where each cell starts (its separator,
    /// if any, included) and how wide its title's room is.
    private var titles: [NSAttributedString] = []
    private var cellX: [CGFloat] = []
    private var cellWidth: [CGFloat] = []
    /// Cells on screen by candidate index, and spare ones to reuse.
    private var shownCells: [Int: CandidateCell] = [:]
    private var spareCells: [CandidateCell] = []
    /// True while reset() rebuilds the strip. The programmatic setContentOffset
    /// fires scrollViewDidScroll against the STALE contentSize (layout hasn't run
    /// yet), and re-entering onNeedMore mid-rebuild would append a prefetched
    /// page ahead of page 1 — cells would no longer line up with the owner's
    /// item indices, so taps would commit a different candidate than displayed.
    private var isResetting = false

    init(theme: KeyboardTheme) {
        self.theme = theme
        super.init(frame: .zero)
        build()
        apply(theme: theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        composingLabel.font = .systemFont(ofSize: 15, weight: .medium)
        composingLabel.setContentHuggingPriority(.required, for: .horizontal)
        composingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        composingLabel.translatesAutoresizingMaskIntoConstraints = false

        scroll.showsHorizontalScrollIndicator = false
        scroll.delegate = self
        scroll.translatesAutoresizingMaskIntoConstraints = false
        Self.hideEdgeEffects(of: scroll)

        // The built-in Pinyin keyboard's affordance: a thin secondary-gray SF Symbol
        // chevron, not a filled text triangle. Starts hidden so the idle bar shows
        // nothing — visibility is decided by reset() once a composition has candidates.
        expandButton.setImage(UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        ), for: .normal)
        expandButton.isHidden = true
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.onTap { [weak self] in self?.onExpand?() }

        topSeparator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(composingLabel)
        addSubview(scroll)
        addSubview(expandButton)
        addSubview(topSeparator)

        NSLayoutConstraint.activate([
            composingLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            composingLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            scroll.leadingAnchor.constraint(equalTo: composingLabel.trailingAnchor, constant: 6),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: expandButton.leadingAnchor),

            expandButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            expandButton.topAnchor.constraint(equalTo: topAnchor),
            expandButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            // 44pt box: the standard touch target, and equal to the grid's close
            // button so the expand/collapse chevron flips in place.
            expandButton.widthAnchor.constraint(equalToConstant: 44),

            topSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            topSeparator.bottomAnchor.constraint(equalTo: bottomAnchor),
            topSeparator.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    /// UIKit's scroll edge effects (iOS 26+) blur content scrolling under a
    /// bar. Inside the extension iOS 27 applies them to the candidates — the
    /// strip sits right under the system keyboard panel's top edge — and the
    /// soft blur covered every candidate. Nothing here ever scrolls under a
    /// bar, so they go.
    static func hideEdgeEffects(of scrollView: UIScrollView) {
        guard #available(iOS 26.0, *) else { return }
        for edge in [scrollView.topEdgeEffect, scrollView.leftEdgeEffect,
                     scrollView.bottomEdgeEffect, scrollView.rightEdgeEffect] {
            edge.isHidden = true
        }
    }

    func apply(theme: KeyboardTheme) {
        let restyled = theme.candidateText != self.theme.candidateText
            || theme.candidateHint != self.theme.candidateHint
            || theme.candidateFontSize != self.theme.candidateFontSize
            || theme.separator != self.theme.separator
        self.theme = theme
        composingLabel.textColor = theme.composingText
        expandButton.tintColor = theme.candidateHint
        topSeparator.backgroundColor = theme.separator
        guard restyled, !candidates.isEmpty else { return }
        let shown = candidates
        candidates = []
        titles = []; cellX = []; cellWidth = []
        recycleAllCells()
        append(shown)
    }

    /// The loaded candidates, kept to re-title them on a theme change.
    private var candidates: [Candidate] = []

    /// Replace the strip with a fresh page.
    func reset(composing: String, items: [Candidate], canExpand: Bool) {
        composingLabel.text = composing
        isResetting = true
        candidates = []
        titles = []; cellX = []; cellWidth = []
        recycleAllCells()
        scroll.setContentOffset(.zero, animated: false)
        append(items)
        isResetting = false
        expandButton.isHidden = !canExpand
    }

    /// Append a freshly-loaded page of candidates (lazy pagination).
    func append(_ items: [Candidate]) {
        guard !items.isEmpty else { return }
        for cand in items {
            let title = Self.title(cand, theme: theme)
            let size = TitleSizes.size(of: title, value: cand.value, hint: cand.hint, fontSize: theme.candidateFontSize)
            let x = cellX.last.map { $0 + leadingSeparator(cellX.count - 1) + cellWidth[cellX.count - 1] } ?? 0
            candidates.append(cand)
            titles.append(title)
            cellX.append(x)
            cellWidth.append((size.width + 2 * Self.titlePadding.width).rounded(.up))
        }
        let last = cellX.count - 1
        scroll.contentSize = CGSize(width: cellX[last] + leadingSeparator(last) + cellWidth[last],
                                    height: scroll.bounds.height)
        showVisibleCells()
    }

    // MARK: - Cells

    /// Room around a title, as the strip's buttons had it: 12pt left and
    /// right, 4pt above and below.
    private static let titlePadding = CGSize(width: 12, height: 4)
    /// Every cell but the first starts with a hairline separator.
    private static let separatorWidth: CGFloat = 0.5
    private static let separatorHeight: CGFloat = 24

    private func leadingSeparator(_ index: Int) -> CGFloat {
        index > 0 ? Self.separatorWidth : 0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if scroll.contentSize.height != scroll.bounds.height, let last = cellX.indices.last {
            scroll.contentSize = CGSize(width: cellX[last] + leadingSeparator(last) + cellWidth[last],
                                        height: scroll.bounds.height)
        }
        showVisibleCells(relayout: true)
    }

    /// Put cells on the candidates on screen and half a screen to either
    /// side; hand the rest back to the pool.
    private func showVisibleCells(relayout: Bool = false) {
        let width = scroll.bounds.width
        guard width > 0, !cellX.isEmpty else { return }
        let minX = scroll.contentOffset.x - width / 2
        let maxX = scroll.contentOffset.x + width * 1.5
        for (index, cell) in shownCells where cellX[index] > maxX || cellX[index] + leadingSeparator(index) + cellWidth[index] < minX {
            shownCells[index] = nil
            recycle(cell)
        }
        // The first candidate that ends past minX, then on while they start before maxX.
        var index = firstCell(endingAfter: minX)
        while index < cellX.count, cellX[index] <= maxX {
            if let cell = shownCells[index] {
                if relayout { place(cell, at: index) }
            } else {
                let cell = spareCells.popLast() ?? makeCell()
                cell.isHidden = false
                cell.index = index
                cell.label.attributedText = titles[index]
                cell.accessibilityLabel = titles[index].string
                cell.separator.backgroundColor = theme.separator
                place(cell, at: index)
                shownCells[index] = cell
            }
            index += 1
        }
    }

    private func firstCell(endingAfter x: CGFloat) -> Int {
        var low = 0, high = cellX.count
        while low < high {
            let mid = (low + high) / 2
            if cellX[mid] + leadingSeparator(mid) + cellWidth[mid] <= x { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The cell spans the strip's height (an easier target than the title
    /// alone). Everything else is where the strip's stack of buttons put it:
    /// each edge snapped to the nearest pixel as Auto Layout snaps them, the
    /// title centered in its padded room in whole pixels.
    private func place(_ cell: CandidateCell, at index: Int) {
        let scale = max(traitCollection.displayScale, 1)
        func pixel(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        func offset(_ space: CGFloat, _ length: CGFloat) -> CGFloat {
            (((space * scale).rounded() - (length * scale).rounded()) / 2).rounded() / scale
        }
        let height = scroll.bounds.height
        let start = pixel(cellX[index])
        let titleStart = pixel(cellX[index] + leadingSeparator(index))
        let end = pixel(cellX[index] + leadingSeparator(index) + cellWidth[index])
        cell.frame = CGRect(x: start, y: 0, width: end - start, height: height)
        cell.separator.isHidden = index == 0
        cell.separator.frame = CGRect(x: 0, y: pixel((height - Self.separatorHeight) / 2),
                                      width: titleStart - start, height: Self.separatorHeight)
        let size = TitleSizes.size(of: titles[index], value: candidates[index].value,
                                   hint: candidates[index].hint, fontSize: theme.candidateFontSize)
        // UIKit sizes a button's title label in whole points.
        let labelSize = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        let buttonHeight = pixel(size.height + 2 * Self.titlePadding.height)
        let buttonTop = pixel((height - buttonHeight) / 2)
        let room = CGSize(width: end - titleStart - 2 * Self.titlePadding.width,
                          height: buttonHeight - 2 * Self.titlePadding.height)
        cell.label.frame = CGRect(
            x: titleStart - start + Self.titlePadding.width + offset(room.width, labelSize.width),
            y: buttonTop + Self.titlePadding.height + offset(room.height, labelSize.height),
            width: labelSize.width, height: labelSize.height)
    }

    private func makeCell() -> CandidateCell {
        let cell = CandidateCell()
        cell.onTap = { [weak self] index in self?.onSelect?(index) }
        scroll.addSubview(cell)
        return cell
    }

    private func recycle(_ cell: CandidateCell) {
        cell.isHidden = true
        cell.label.attributedText = nil
        spareCells.append(cell)
    }

    private func recycleAllCells() {
        for cell in shownCells.values { recycle(cell) }
        shownCells.removeAll()
    }

    static func title(_ cand: Candidate, theme: KeyboardTheme) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: cand.value,
            attributes: [.font: UIFont.systemFont(ofSize: theme.candidateFontSize), .foregroundColor: theme.candidateText]
        )
        if let hint = cand.hint, !hint.isEmpty {
            result.append(NSAttributedString(
                string: " 〔\(hint)〕",
                attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: theme.candidateHint]
            ))
        }
        return result
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        showVisibleCells()
        guard !isResetting else { return }
        let nearEnd = scrollView.contentOffset.x + scrollView.bounds.width * 2 >= scrollView.contentSize.width
        if nearEnd { onNeedMore?() }
    }
}

/// One candidate in the strip: its title, and the hairline separating it from
/// the one before. Reused as the strip scrolls and on every keystroke.
private final class CandidateCell: UIControl {
    let label = UILabel()
    let separator = UIView()
    var index = 0
    var onTap: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.isUserInteractionEnabled = false
        separator.isUserInteractionEnabled = false
        addSubview(separator)
        addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .button
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Pressed, the title dims as a system button's does.
    override var isHighlighted: Bool {
        didSet { label.alpha = isHighlighted ? 0.2 : 1 }
    }

    @objc private func tapped() { onTap?(index) }
}

/// Measured candidate titles. A title's size depends only on its text and the
/// font size, and the same few thousand candidates come back keystroke after
/// keystroke, so each is measured once; the cache is dropped if it ever grows
/// past a few thousand.
private enum TitleSizes {
    private struct Key: Hashable {
        let value: String
        let hint: String?
        let fontSize: CGFloat
    }
    private static var sizes: [Key: CGSize] = [:]

    static func size(of title: NSAttributedString, value: String, hint: String?, fontSize: CGFloat) -> CGSize {
        let key = Key(value: value, hint: hint, fontSize: fontSize)
        if let size = sizes[key] { return size }
        if sizes.count > 4096 { sizes.removeAll() }
        let size = title.size()
        sizes[key] = size
        return size
    }
}
