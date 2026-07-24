import UIKit

/// The enlarged preview shown while a character key is pressed, shaped like the
/// built-in keyboard's callout: a wide balloon that necks down to exactly the
/// key's width and flows over the key itself in one continuous outline, so the
/// glyph sits clear of the finger. Classic: a solid fill with the popup shadow.
/// Liquid glass: a blur material masked to the callout, frosted to the system
/// callout's brightness (not `UIGlassEffect` — see the note in `init`).
final class KeyPopupView: UIView {
    private let label = UILabel()

    /// Sizes and positions itself around `keyFrame` (in the host's coordinate
    /// space): the stem overlays the key exactly; the balloon flares to the
    /// sides and up. An edge key gives up overhang on its outer side and
    /// regains it on the inner side, like the system keyboard's edge callouts.
    init(text: String, theme: KeyboardTheme, keyFrame: CGRect, hostBounds: CGRect) {
        // Balloon overhang per side: proportional on phone-portrait letter keys
        // (matches the system callout), capped so wide landscape keys don't
        // produce an outsized balloon.
        let flare = min(keyFrame.width * 0.35, 14)
        let edgeMargin: CGFloat = 2
        let leftRoom = max(0, keyFrame.minX - hostBounds.minX - edgeMargin)
        let rightRoom = max(0, hostBounds.maxX - keyFrame.maxX - edgeMargin)
        let leftFlare = min(flare + max(0, flare - rightRoom), leftRoom)
        let rightFlare = min(flare + max(0, flare - leftRoom), rightRoom)

        // Balloon + neck above the key top, in the system keyboard's proportions.
        // The extension cannot draw above its own surface (the system keyboard
        // overflows the panel there), so when headroom runs out — the top row —
        // the neck dips into the key rather than squashing the balloon.
        let neckHeight: CGFloat = 13
        let idealAbove = keyFrame.height + neckHeight
        let headroom = keyFrame.minY - hostBounds.minY
        let overlap = min(max(0, idealAbove - headroom), 10)
        let aboveKey = min(idealAbove - overlap, headroom)
        let balloonHeight = aboveKey + overlap - neckHeight

        super.init(frame: CGRect(
            x: keyFrame.minX - leftFlare,
            y: keyFrame.minY - aboveKey,
            width: keyFrame.width + leftFlare + rightFlare,
            height: aboveKey + keyFrame.height
        ))
        isUserInteractionEnabled = false

        let path = Self.calloutPath(
            size: bounds.size,
            stemX: leftFlare,
            stemWidth: keyFrame.width,
            neckBottom: balloonHeight + neckHeight,
            minNeckSpan: neckHeight,
            topRadius: theme.style == .liquidGlass ? 22 : 10,
            bottomRadius: theme.keyCornerRadius
        )

        label.text = text
        label.textColor = theme.popupText
        label.font = .systemFont(ofSize: 32)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

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
            glow.frame = CGRect(x: leftFlare, y: glowTop,
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
            bubble.contentView.addSubview(label)
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
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: topAnchor, constant: balloonHeight / 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// One closed outline: rounded balloon top, an S-curve neck per side with
    /// vertical tangents at both ends, and a stem with key-radius bottom
    /// corners. Each side's curve spans at least its horizontal travel, so an
    /// edge key's long inner sweep stays diagonal instead of shelving flat.
    private static func calloutPath(
        size: CGSize,
        stemX: CGFloat,
        stemWidth: CGFloat,
        neckBottom: CGFloat,
        minNeckSpan: CGFloat,
        topRadius: CGFloat,
        bottomRadius: CGFloat
    ) -> UIBezierPath {
        let w = size.width
        let h = size.height
        let topR = min(topRadius, (neckBottom - minNeckSpan) / 2, w / 2)
        let botR = bottomRadius
        let stemRight = stemX + stemWidth
        let maxSpan = neckBottom - topR - 2
        let leftSpan = min(max(minNeckSpan, stemX), maxSpan)
        let rightSpan = min(max(minNeckSpan, w - stemRight), maxSpan)

        let p = UIBezierPath()
        p.move(to: CGPoint(x: topR, y: 0))
        p.addLine(to: CGPoint(x: w - topR, y: 0))
        p.addArc(withCenter: CGPoint(x: w - topR, y: topR), radius: topR,
                 startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        p.addLine(to: CGPoint(x: w, y: neckBottom - rightSpan))
        p.addCurve(to: CGPoint(x: stemRight, y: neckBottom),
                   controlPoint1: CGPoint(x: w, y: neckBottom - rightSpan / 2),
                   controlPoint2: CGPoint(x: stemRight, y: neckBottom - rightSpan / 2))
        p.addLine(to: CGPoint(x: stemRight, y: h - botR))
        p.addArc(withCenter: CGPoint(x: stemRight - botR, y: h - botR), radius: botR,
                 startAngle: 0, endAngle: .pi / 2, clockwise: true)
        p.addLine(to: CGPoint(x: stemX + botR, y: h))
        p.addArc(withCenter: CGPoint(x: stemX + botR, y: h - botR), radius: botR,
                 startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        p.addLine(to: CGPoint(x: stemX, y: neckBottom))
        p.addCurve(to: CGPoint(x: 0, y: neckBottom - leftSpan),
                   controlPoint1: CGPoint(x: stemX, y: neckBottom - leftSpan / 2),
                   controlPoint2: CGPoint(x: 0, y: neckBottom - leftSpan / 2))
        p.addLine(to: CGPoint(x: 0, y: topR))
        p.addArc(withCenter: CGPoint(x: topR, y: topR), radius: topR,
                 startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: true)
        p.close()
        return p
    }
}
