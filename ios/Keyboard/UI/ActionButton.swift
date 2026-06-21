import UIKit

/// Closure-based UIButton (UIAction's `addAction` is iOS 14+; the floor is iOS 13).
final class ActionButton: UIButton {
    private var handler: (() -> Void)?
    func onTap(_ handler: @escaping () -> Void) {
        self.handler = handler
        addTarget(self, action: #selector(fire), for: .touchUpInside)
    }
    @objc private func fire() { handler?() }
}
