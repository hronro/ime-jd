import UIKit

/// Closure-based UIButton — a shim from when the floor was iOS 13 (UIAction's
/// `addAction` is iOS 14+); at today's iOS 15 floor `addAction` would do.
final class ActionButton: UIButton {
    private var handler: (() -> Void)?
    func onTap(_ handler: @escaping () -> Void) {
        self.handler = handler
        addTarget(self, action: #selector(fire), for: .touchUpInside)
    }
    @objc private func fire() { handler?() }
}
