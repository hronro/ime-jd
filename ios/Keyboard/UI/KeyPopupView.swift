import UIKit

/// The key-press callout, shaped like the built-in keyboard's: a wide balloon
/// that necks down to exactly the key's width and flows over the key itself in
/// one continuous outline, so the content sits clear of the finger. Two
/// contents: the enlarged glyph shown while a key is pressed, and the
/// press-and-hold row of grouped alternates the finger slides across
/// (`KeyButton` drives the selection). Classic: a solid fill with the popup
/// shadow. Liquid glass: a blur material masked to the callout, frosted to the
/// system callout's brightness (not `UIGlassEffect` — see the note in `init`).
///
/// Floating variants follow the newer system keyboards: iOS 27 shows the
/// pressed glyph in a rounded bubble hovering above the key, and both iOS 26
/// and 27 pick alternates in a rounded panel hovering above the row (see
/// `init(floating:…)`).
final class KeyPopupView: UIView {
    private let theme: KeyboardTheme
    private var displayValues: [String] = []
    private var labels: [UILabel] = []
    /// 半/全 corner tags on width twins (@ vs ＠ …); nil for unambiguous cells.
    private var badges: [UILabel?] = []
    private var highlight: CALayer?
    /// True when the display order is right-to-left (a right-half key's group
    /// extends left, keeping the primary above the finger).
    private var reversed = false
    private var contentLeft: CGFloat = 0
    private var cellWidth: CGFloat = 0
    /// A floating shape hovers apart from the key (see `init(floating:…)`).
    private var floating = false
    /// The pressed key's bottom edge, in this view's coordinates: sliding well
    /// below it drops the alternates selection.
    private var keyBottom: CGFloat = 0
    private var selectedDisplay: Int? { didSet { if selectedDisplay != oldValue { renderSelection() } } }

    /// The highlighted alternate (nil when the finger slid away from the row).
    var selectedValue: String? { selectedDisplay.map { displayValues[$0] } }

    /// The enlarged single-glyph preview above a pressed key. `glyphSize` is
    /// the key's own font size (the floating bubble scales from it).
    convenience init(text: String, theme: KeyboardTheme, keyFrame: CGRect, hostBounds: CGRect,
                     glyphSize: CGFloat) {
        if theme.detachedCallout {
            self.init(floating: [text], alternatesRow: false, theme: theme,
                      keyFrame: keyFrame, hostBounds: hostBounds, glyphSize: glyphSize)
        } else {
            self.init(values: [text], alternatesRow: false, theme: theme,
                      keyFrame: keyFrame, hostBounds: hostBounds)
        }
    }

    /// The expanded press-and-hold group (primary first). Cells extend toward
    /// the screen's center — reversed on the right half — so the callout stays
    /// on-screen and the primary starts out directly above the finger.
    convenience init(alternates values: [String], theme: KeyboardTheme, keyFrame: CGRect, hostBounds: CGRect,
                     glyphSize: CGFloat) {
        if theme.style == .liquidGlass {
            self.init(floating: values, alternatesRow: true, theme: theme,
                      keyFrame: keyFrame, hostBounds: hostBounds, glyphSize: glyphSize)
        } else {
            self.init(values: values, alternatesRow: true, theme: theme,
                      keyFrame: keyFrame, hostBounds: hostBounds)
        }
    }

    /// The floating shapes, measured off the stock keyboard on the iOS 26.5
    /// and 27.0 iPhone simulators (in points; 3x pixels / 3):
    /// - iOS 27 bubble: 12.17 wider than the key on each side, 65.67 tall,
    ///   3.33 above the key, the glyph 1.54x the key's.
    /// - Alternates panel (26 and 27): 67.67 tall, 3.33 (27) / 5.67 (26) above
    ///   the key, cells up to 37.5 wide (narrower when the row would not fit),
    ///   the glyph at the key's size, the selection a 47-tall rounded cell.
    /// Light fills are white with a soft shadow; dark ones a frosted material
    /// (see below). Like the stock bubble, either shape may run to the screen
    /// edge; one that would rise past this extension's top edge — which it
    /// cannot draw beyond — slides down over its key instead.
    private init(floating values: [String], alternatesRow: Bool, theme: KeyboardTheme,
                 keyFrame: CGRect, hostBounds: CGRect, glyphSize: CGFloat) {
        self.theme = theme
        let ios27 = theme.detachedCallout
        let gap: CGFloat = ios27 ? 10.0 / 3 : 17.0 / 3
        let height: CGFloat = alternatesRow ? 203.0 / 3 : 197.0 / 3
        var frame: CGRect
        if alternatesRow {
            let pad: CGFloat = ios27 ? 31.0 / 3 : 21.75 / 3
            let cellWidth = min(112.5 / 3, (hostBounds.width - 2 * pad) / CGFloat(values.count))
            let width = CGFloat(values.count) * cellWidth + 2 * pad
            let reversed = keyFrame.midX > hostBounds.midX
            // The cell nearest the key centers over it; the rest extend inward.
            let x = reversed
                ? keyFrame.midX + pad + cellWidth / 2 - width
                : keyFrame.midX - pad - cellWidth / 2
            frame = CGRect(x: x, y: keyFrame.minY - gap - height, width: width, height: height)
            self.reversed = reversed
            self.contentLeft = pad
            self.cellWidth = cellWidth
            self.displayValues = reversed ? values.reversed() : values
        } else {
            let width = keyFrame.width + 2 * (73.0 / 6)
            frame = CGRect(x: keyFrame.midX - width / 2, y: keyFrame.minY - gap - height,
                           width: width, height: height)
            self.displayValues = values
            self.cellWidth = width
        }
        frame.origin.x = min(max(frame.minX, hostBounds.minX), hostBounds.maxX - frame.width)
        frame.origin.y = max(frame.minY, hostBounds.minY)

        super.init(frame: frame)
        isUserInteractionEnabled = false
        floating = true
        keyBottom = keyFrame.maxY - frame.minY

        // Light: near-opaque white (measured 253), with a soft shadow. Dark: a
        // frosted material — keys behind the stock shapes show through as
        // soft, lighter blobs (`UIGlassEffect` keeps them legible, too clear),
        // brightening toward the bottom.
        let radius: CGFloat = alternatesRow ? 20 : 15
        let body: UIView
        if theme.isDark {
            let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
            material.frame = bounds
            material.layer.cornerRadius = radius
            material.layer.cornerCurve = .continuous
            material.clipsToBounds = true
            let frost = CAGradientLayer()
            frost.frame = bounds
            frost.colors = [UIColor(white: 1, alpha: 0.065).cgColor, UIColor(white: 1, alpha: 0.145).cgColor]
            material.contentView.layer.addSublayer(frost)
            addSubview(material)
            body = material.contentView
        } else {
            body = UIView(frame: bounds)
            body.backgroundColor = .white
            body.layer.cornerRadius = radius
            body.layer.cornerCurve = .continuous
            addSubview(body)
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.11
            layer.shadowRadius = 6
            layer.shadowOffset = CGSize(width: 0, height: 1)
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
        }

        if alternatesRow {
            let hl = CALayer()
            hl.backgroundColor = theme.alternatesHighlight.cgColor
            hl.cornerRadius = 9.5
            hl.cornerCurve = .continuous
            hl.isHidden = true
            body.layer.addSublayer(hl)
            highlight = hl
        }
        addLabels(to: body, height: bounds.height, alternatesRow: alternatesRow,
                  font: .systemFont(ofSize: alternatesRow ? glyphSize : glyphSize * 1.54))
    }

    private init(values: [String], alternatesRow: Bool, theme: KeyboardTheme,
                 keyFrame: CGRect, hostBounds: CGRect) {
        self.theme = theme

        // Balloon + neck above the key top, in the system keyboard's proportions:
        // iOS 26's necks down right above the key; the pre-26 one (measured on
        // iOS 18.6) rises higher — 23pt more than the key is tall — and necks
        // down over a longer sweep that ends inside the key. The extension
        // cannot draw above its own surface (the system keyboard overflows the
        // panel there), so if headroom ever runs out the neck dips further
        // into the key rather than squashing the balloon. (The candidate bar
        // is sized so standard layouts fit with little dipping — see
        // CandidateBarView.)
        let classic = theme.style == .classic
        let neckHeight: CGFloat = classic ? 17 : 13
        let dip: CGFloat = classic ? 4 : 0
        let idealAbove = keyFrame.height + (classic ? 23 : neckHeight)
        let headroom = keyFrame.minY - hostBounds.minY
        let shortfall = min(max(0, idealAbove - headroom), 10)
        let overlap = dip + shortfall
        let aboveKey = min(idealAbove - shortfall, headroom)
        let balloonHeight = aboveKey + overlap - neckHeight

        let frame: CGRect
        let reversed: Bool
        if alternatesRow {
            reversed = keyFrame.midX > hostBounds.midX
            let pad: CGFloat = 6
            let cellWidth = max(keyFrame.width, 36)
            let width = CGFloat(values.count) * cellWidth + 2 * pad
            // The cell nearest the key centers over it; the rest extend inward.
            var x = reversed
                ? keyFrame.midX + pad + cellWidth / 2 - width
                : keyFrame.midX - pad - cellWidth / 2
            x = min(max(x, hostBounds.minX + 2), hostBounds.maxX - 2 - width)
            frame = CGRect(x: x, y: keyFrame.minY - aboveKey,
                           width: width, height: aboveKey + keyFrame.height)
            self.reversed = reversed
            self.contentLeft = pad
            self.cellWidth = cellWidth
            self.displayValues = reversed ? values.reversed() : values
        } else {
            reversed = false
            // Balloon overhang per side: proportional on phone-portrait letter
            // keys (matches the system callout), capped so wide landscape keys
            // don't produce an outsized balloon. An edge key gives up overhang
            // on its outer side and regains it on the inner side.
            let flare = min(keyFrame.width * (classic ? 0.37 : 0.35), 14)
            let edgeMargin: CGFloat = 2
            let leftRoom = max(0, keyFrame.minX - hostBounds.minX - edgeMargin)
            let rightRoom = max(0, hostBounds.maxX - keyFrame.maxX - edgeMargin)
            let leftFlare = min(flare + max(0, flare - rightRoom), leftRoom)
            let rightFlare = min(flare + max(0, flare - leftRoom), rightRoom)
            frame = CGRect(x: keyFrame.minX - leftFlare,
                           y: keyFrame.minY - aboveKey,
                           width: keyFrame.width + leftFlare + rightFlare,
                           height: aboveKey + keyFrame.height)
            self.displayValues = values
            self.contentLeft = 0
            self.cellWidth = frame.width
        }

        super.init(frame: frame)
        isUserInteractionEnabled = false

        let stemX = keyFrame.minX - frame.minX
        let path = Self.calloutPath(
            size: bounds.size,
            stemX: stemX,
            stemWidth: keyFrame.width,
            balloonHeight: balloonHeight,
            neckHeight: neckHeight,
            topRadius: theme.style == .liquidGlass ? 22 : 10,
            bottomRadius: theme.keyCornerRadius
        )

        // The view (or effect contentView) that carries cells and highlight.
        let content: UIView
        if theme.style == .liquidGlass {
            // Not `UIGlassEffect`: UIKit has no glass API for arbitrary shapes,
            // and masking a glass effect view disables its shape-aware
            // rendering (no blur, no lensing) — keys behind the balloon show
            // through as hard silhouettes. A masked blur material diffuses
            // them like the system callout does.
            let bubble = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
            bubble.frame = bounds
            addSubview(bubble)
            // Frost + stem glow, calibrated against the system callout: the raw
            // material runs darker than the stock balloon, whose stem is also
            // brighter where the pressed key shines through. The glow is
            // stem-wide and fades in around the neck bottom, so no hard edge
            // shows where it starts.
            bubble.contentView.backgroundColor = UIColor(white: 1, alpha: 0.08)
            let fade: CGFloat = 12
            let glowTop = balloonHeight + neckHeight - fade
            let glow = CAGradientLayer()
            glow.frame = CGRect(x: stemX, y: glowTop,
                                width: keyFrame.width, height: bounds.height - glowTop)
            glow.colors = [UIColor(white: 1, alpha: 0).cgColor,
                           UIColor(white: 1, alpha: 0.12).cgColor]
            glow.locations = [0, NSNumber(value: Double(fade / glow.frame.height))]
            let glowMask = CAShapeLayer()
            glowMask.path = UIBezierPath(
                roundedRect: CGRect(origin: .zero, size: glow.frame.size),
                byRoundingCorners: [.bottomLeft, .bottomRight],
                cornerRadii: CGSize(width: theme.keyCornerRadius, height: theme.keyCornerRadius)
            ).cgPath
            glow.mask = glowMask
            bubble.contentView.layer.addSublayer(glow)
            let mask = UIView(frame: bounds)
            let shape = CAShapeLayer()
            shape.path = path.cgPath
            mask.layer.addSublayer(shape)
            bubble.mask = mask
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.25
            layer.shadowRadius = 5
            layer.shadowOffset = CGSize(width: 0, height: 2)
            layer.shadowPath = path.cgPath
            content = bubble.contentView
        } else {
            let shape = CAShapeLayer()
            shape.path = path.cgPath
            shape.fillColor = theme.popupBackground.cgColor
            layer.addSublayer(shape)
            layer.shadowColor = theme.keyShadow.cgColor
            layer.shadowOpacity = 0.35
            layer.shadowRadius = 3
            layer.shadowOffset = CGSize(width: 0, height: 2)
            layer.shadowPath = path.cgPath
            content = self
        }

        keyBottom = bounds.height
        if alternatesRow {
            // Selection highlight behind the labels (moved by renderSelection).
            let hl = CALayer()
            hl.backgroundColor = theme.alternatesHighlight.cgColor
            hl.cornerRadius = 8
            hl.cornerCurve = .continuous
            hl.isHidden = true
            content.layer.addSublayer(hl)
            highlight = hl
        }
        // The pre-26 balloon's glyph is light — a small letter 40pt, a capital
        // 37.5pt — and sits a little below the balloon's middle (iOS 18.6).
        let classicGlyph = classic && !alternatesRow
        let smallLetter = values.first.map { $0 != $0.uppercased() } ?? false
        addLabels(to: content, height: balloonHeight, alternatesRow: alternatesRow,
                  font: alternatesRow ? .systemFont(ofSize: 24)
                      : classic ? .systemFont(ofSize: smallLetter ? 40 : 37.5, weight: .light)
                      : .systemFont(ofSize: 32),
                  drop: classicGlyph ? 1.7 : 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Height of the floating panel's selection cell (centered in the panel).
    private static let floatingHighlightHeight: CGFloat = 141.0 / 3

    /// One label per value across the cells, plus the 半/全 tags of width
    /// twins; an alternates row starts with its primary selected.
    private func addLabels(to content: UIView, height: CGFloat, alternatesRow: Bool, font: UIFont,
                           drop: CGFloat = 0) {
        let badgeTop = floating ? (height - Self.floatingHighlightHeight) / 2 + 3 : 3
        for (i, value) in displayValues.enumerated() {
            let label = UILabel()
            label.text = value
            label.textColor = theme.popupText
            label.font = font
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.5
            label.textAlignment = .center
            label.frame = CGRect(x: contentLeft + CGFloat(i) * cellWidth, y: drop,
                                 width: cellWidth, height: height)
            content.addSubview(label)
            labels.append(label)
            // A width pair in one group (@ and ＠) is two near-identical
            // faces — a small 半/全 tag in each cell's top-left corner is
            // what tells them apart.
            if alternatesRow,
               let badge = KeyLayout.widthBadge(for: value, inGroup: displayValues) {
                let tag = UILabel()
                tag.text = badge
                tag.font = .systemFont(ofSize: 9, weight: .medium)
                tag.textColor = theme.popupText.withAlphaComponent(0.55)
                tag.frame = CGRect(x: label.frame.minX + 4, y: badgeTop, width: 14, height: 11)
                content.addSubview(tag)
                badges.append(tag)
            } else {
                badges.append(nil)
            }
        }
        if alternatesRow {
            // Start on the primary — the cell above the finger.
            selectedDisplay = reversed ? displayValues.count - 1 : 0
            renderSelection()
        }
    }

    // MARK: - Alternates selection (driven by KeyButton's touch tracking)

    /// Update the highlighted cell for a touch in the POPUP's coordinate space.
    /// X is clamped into the row; sliding well below the key deselects.
    func updateSelection(forTouch point: CGPoint) {
        guard !displayValues.isEmpty, highlight != nil else { return }
        if point.y > keyBottom + 30 {
            selectedDisplay = nil
            return
        }
        let i = Int(floor((point.x - contentLeft) / cellWidth))
        selectedDisplay = min(max(i, 0), displayValues.count - 1)
    }

    /// QA hook: highlight by index into the ORIGINAL group order (0 = primary).
    func selectValue(at index: Int) {
        guard index >= 0, index < displayValues.count else { return }
        selectedDisplay = reversed ? displayValues.count - 1 - index : index
    }

    private func renderSelection() {
        guard let hl = highlight else { return }
        if let i = selectedDisplay {
            hl.isHidden = false
            hl.frame = floating
                ? CGRect(x: labels[i].frame.minX, y: (bounds.height - Self.floatingHighlightHeight) / 2,
                         width: cellWidth, height: Self.floatingHighlightHeight)
                : labels[i].frame.insetBy(dx: 2, dy: 4)
        } else {
            hl.isHidden = true
        }
        for (j, label) in labels.enumerated() {
            let selected = j == selectedDisplay
            label.textColor = selected ? theme.alternatesHighlightText : theme.popupText
            badges[j]?.textColor = selected
                ? theme.alternatesHighlightText.withAlphaComponent(0.85)
                : theme.popupText.withAlphaComponent(0.55)
        }
    }

    // MARK: - Outline

    /// One closed outline: rounded balloon top, stem with key-radius bottom
    /// corners. A side with modest overhang necks down with an S-curve whose
    /// span is at least its horizontal travel (an edge key's long inner sweep
    /// stays diagonal instead of shelving flat); a side that overhangs far —
    /// the wide alternates balloon — closes with a normal rounded corner and
    /// a small concave fillet where the stem meets the balloon's underside.
    private static func calloutPath(
        size: CGSize,
        stemX: CGFloat,
        stemWidth: CGFloat,
        balloonHeight: CGFloat,
        neckHeight: CGFloat,
        topRadius: CGFloat,
        bottomRadius: CGFloat
    ) -> UIBezierPath {
        let w = size.width
        let h = size.height
        let topR = min(topRadius, balloonHeight / 2, w / 2)
        let botR = bottomRadius
        let stemRight = stemX + stemWidth
        let neckBottom = balloonHeight + neckHeight
        let maxSpan = neckBottom - topR - 2
        let sCurveMaxFlare: CGFloat = 36
        let fillet = min(neckHeight, 10)

        let p = UIBezierPath()
        p.move(to: CGPoint(x: topR, y: 0))
        p.addLine(to: CGPoint(x: w - topR, y: 0))
        p.addArc(withCenter: CGPoint(x: w - topR, y: topR), radius: topR,
                 startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        let rightFlare = w - stemRight
        if rightFlare <= sCurveMaxFlare {
            let span = min(max(neckHeight, rightFlare), maxSpan)
            p.addLine(to: CGPoint(x: w, y: neckBottom - span))
            p.addCurve(to: CGPoint(x: stemRight, y: neckBottom),
                       controlPoint1: CGPoint(x: w, y: neckBottom - span / 2),
                       controlPoint2: CGPoint(x: stemRight, y: neckBottom - span / 2))
        } else {
            p.addLine(to: CGPoint(x: w, y: balloonHeight - topR))
            p.addArc(withCenter: CGPoint(x: w - topR, y: balloonHeight - topR), radius: topR,
                     startAngle: 0, endAngle: .pi / 2, clockwise: true)
            p.addLine(to: CGPoint(x: stemRight + fillet, y: balloonHeight))
            p.addArc(withCenter: CGPoint(x: stemRight + fillet, y: balloonHeight + fillet),
                     radius: fillet,
                     startAngle: -.pi / 2, endAngle: .pi, clockwise: false)
        }
        p.addLine(to: CGPoint(x: stemRight, y: h - botR))
        p.addArc(withCenter: CGPoint(x: stemRight - botR, y: h - botR), radius: botR,
                 startAngle: 0, endAngle: .pi / 2, clockwise: true)
        p.addLine(to: CGPoint(x: stemX + botR, y: h))
        p.addArc(withCenter: CGPoint(x: stemX + botR, y: h - botR), radius: botR,
                 startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        let leftFlare = stemX
        if leftFlare <= sCurveMaxFlare {
            let span = min(max(neckHeight, leftFlare), maxSpan)
            p.addLine(to: CGPoint(x: stemX, y: neckBottom))
            p.addCurve(to: CGPoint(x: 0, y: neckBottom - span),
                       controlPoint1: CGPoint(x: stemX, y: neckBottom - span / 2),
                       controlPoint2: CGPoint(x: 0, y: neckBottom - span / 2))
        } else {
            p.addLine(to: CGPoint(x: stemX, y: balloonHeight + fillet))
            p.addArc(withCenter: CGPoint(x: stemX - fillet, y: balloonHeight + fillet),
                     radius: fillet,
                     startAngle: 0, endAngle: -.pi / 2, clockwise: false)
            p.addLine(to: CGPoint(x: topR, y: balloonHeight))
            p.addArc(withCenter: CGPoint(x: topR, y: balloonHeight - topR), radius: topR,
                     startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        }
        p.addLine(to: CGPoint(x: 0, y: topR))
        p.addArc(withCenter: CGPoint(x: topR, y: topR), radius: topR,
                 startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: true)
        p.close()
        return p
    }
}
