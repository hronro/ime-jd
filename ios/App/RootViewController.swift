import UIKit

/// Container-app landing screen: explains how to enable the keyboard system-wide,
/// and offers an in-app preview to try it immediately.
final class RootViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "键道"

        let titleLabel = UILabel()
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.text = "键道输入法"

        let steps = UILabel()
        steps.numberOfLines = 0
        steps.font = .systemFont(ofSize: 16)
        steps.text = """
        系统启用方法：

        1. 打开「设置」▸「通用」▸「键盘」▸「键盘」
        2. 轻点「添加新键盘…」
        3. 选择「键道」

        无需开启「完全访问权限」。
        """

        let tryButton = ActionButton(type: .system)
        tryButton.setTitle("在应用内试用键盘 →", for: .normal)
        tryButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        tryButton.backgroundColor = .systemBlue
        tryButton.setTitleColor(.white, for: .normal)
        tryButton.layer.cornerRadius = 10
        tryButton.translatesAutoresizingMaskIntoConstraints = false
        tryButton.heightAnchor.constraint(equalToConstant: 52).isActive = true
        tryButton.onTap { [weak self] in
            self?.navigationController?.pushViewController(KeyboardPreviewViewController(), animated: true)
        }

        let stack = UIStackView(arrangedSubviews: [titleLabel, steps, tryButton])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: g.topAnchor, constant: 32),
        ])
    }
}
