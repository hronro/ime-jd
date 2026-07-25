import UIKit

/// The key-press callout, shaped like the built-in keyboard's: a wide balloon
/// that necks down to exactly the key's width and flows over the key itself in
/// one continuous outline, so the content sits clear of the finger. Two
/// contents: the enlarged glyph shown while a key is pressed, and the
/// press-and-hold row of grouped alternates the finger slides across
/// (`KeyButton` drives the selection). Classic: a solid fill with the popup
/// shadow. Liquid glass: a blur material masked to the callout, frosted to the
/// system callout's brightness (not `UIGlassEffect` — see the note in `init`).
final class KeyPopupView: UIView {
    private let theme: KeyboardTheme
    private var displayValues: [String] = []
    private var labels: [UILabel] = []
    private var highlight: CALayer?
    /// True when the display order is right-to-left (a right-half key's group
    /// extends left, keeping the primary above the finger).
    private var reversed = false
    private var contentLeft: CGFloat = 0
    private var cellWidth: CGFloat = 0
    private var selectedDisplay: Int? { didSet { if selectedDisplay != oldValue { renderSelection() } } }

    /// The highlighted alternate (nil when the finger slid away from the row).
    var selectedValue: String? { selectedDisplay.map { displayValues[$0] } }

    /// The enlarged single-glyph preview above a pressed key.
    convenience init(text: String, theme: KeyboardTheme, keyFrame: CGRect, hostBounds: CGRect) {
        self.init(values: [text], alternatesRow: false, theme: theme,
                  keyFrame: keyFrame, hostBounds: hostBounds)
    }

    /// The expanded press-and-hold group (primary first). Cells extend toward
    /// the screen's center — reversed on the right half — so the callout stays
    /// on-screen and the primary starts out directly above the finger.
    convenience init(alternates values: [String], theme: KeyboardTheme, keyFrame: CGRect, hostBounds: CGRect) {
        self.init(values: values, alternatesRow: true, theme: theme,
                  keyFrame: keyFrame, hostBounds: hostBounds)
    }

    private init(values: [String], alternatesRow: Bool, theme: KeyboardTheme,
                 keyFrame: CGRect, hostBounds: CGRect) {
        self.theme = theme

        // Balloon + neck above the key top, in the system keyboard's proportions.
        // The extension cannot draw above its own surface (the system keyboard
        // overflows the panel there), so if headroom ever runs out the neck dips
        // into the key rather than squashing the balloon. (The candidate bar is
        // sized so standard layouts fit without dipping — see CandidateBarView.)
        let neckHeight: CGFloat = 13
        let idealAbove = keyFrame.height + neckHeight
        let headroom = keyFrame.minY - hostBounds.minY
        let overlap = min(max(0, idealAbove - headroom), 10)
        let aboveKey = min(idealAbove - overlap, headroom)
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
            let flare = min(keyFrame.width * 0.35, 14)
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

        if alternatesRow {
            // Selection highlight behind the labels (moved by renderSelection).
            let hl = CALayer()
            hl.backgroundColor = UIColor.systemBlue.cgColor
            hl.cornerRadius = 8
            hl.cornerCurve = .continuous
            hl.isHidden = true
            content.layer.addSublayer(hl)
            highlight = hl
        }
        for (i, value) in displayValues.enumerated() {
            let label = UILabel()
            label.text = value
            label.textColor = theme.popupText
            label.font = .systemFont(ofSize: alternatesRow ? 24 : 32)
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.5
            label.textAlignment = .center
            label.frame = CGRect(x: contentLeft + CGFloat(i) * cellWidth, y: 0,
                                 width: cellWidth, height: balloonHeight)
            content.addSubview(label)
            labels.append(label)
        }
        if alternatesRow {
            // Start on the primary — the cell above the finger.
            selectedDisplay = reversed ? displayValues.count - 1 : 0
            renderSelection()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Alternates selection (driven by KeyButton's touch tracking)

    /// Update the highlighted cell for a touch in the POPUP's coordinate space.
    /// X is clamped into the row; sliding well below the key deselects.
    func updateSelection(forTouch point: CGPoint) {
        guard !displayValues.isEmpty, highlight != nil else { return }
        if point.y > bounds.height + 30 {
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
            hl.frame = labels[i].frame.insetBy(dx: 2, dy: 4)
        } else {
            hl.isHidden = true
        }
        for (j, label) in labels.enumerated() {
            label.textColor = j == selectedDisplay ? .white : theme.popupText
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
