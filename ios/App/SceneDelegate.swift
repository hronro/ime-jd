import UIKit

/// Owns the container app's single window. Apps built with the iOS 27 SDK
/// must adopt the UIScene life cycle — one that still sets up its window in
/// the app delegate fails to launch.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // `-userdict "词<TAB>编码;词<TAB>编码"` QA launch arg: seed the user
        // dictionary with these phrases (replacing the file) and switch it on,
        // so the preview and the real extension can be driven with a known
        // phrase and no typing in the list.
        if let i = CommandLine.arguments.firstIndex(of: "-userdict"),
           CommandLine.arguments.indices.contains(i + 1) {
            let entries = CommandLine.arguments[i + 1].split(separator: ";").map { line -> UserDictEntry in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                return UserDictEntry(value: String(parts[0]), keys: parts.count > 1 ? String(parts[1]) : "")
            }
            try? UserDictStore.shared.save(entries)
            UserDictStore.shared.isEnabled = true
        }
        // `-userdictonly 1|0` QA launch arg: set 忽略内置词库 (and switch the
        // user dictionary on), so the built-in-off path is driven with no taps.
        if let i = CommandLine.arguments.firstIndex(of: "-userdictonly"),
           CommandLine.arguments.indices.contains(i + 1) {
            UserDictStore.shared.isEnabled = true
            UserDictStore.shared.isUserOnly = CommandLine.arguments[i + 1] == "1"
        }
        // `-userdictlist` QA launch arg: open the phrase list on top.
        let showsList = CommandLine.arguments.contains("-userdictlist")
        // `-preview` launch arg jumps straight to the in-app keyboard preview
        // (used for screenshots / QA); normal launches land on the guide.
        let root: UIViewController = CommandLine.arguments.contains("-preview")
            ? KeyboardPreviewViewController()
            : RootViewController()
        let navigation = UINavigationController(rootViewController: root)
        // `-lookup <word>` QA launch arg: open 编码反查 on top of the guide
        // with the word already looked up, for screenshots with no taps.
        if let i = CommandLine.arguments.firstIndex(of: "-lookup"),
           CommandLine.arguments.indices.contains(i + 1) {
            navigation.pushViewController(
                CodeLookupViewController(query: CommandLine.arguments[i + 1]), animated: false
            )
        }
        if showsList {
            navigation.pushViewController(UserDictListViewController(), animated: false)
        }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        self.window = window
    }
}
