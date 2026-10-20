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
        // `-preview` launch arg jumps straight to the in-app keyboard preview
        // (used for screenshots / QA); normal launches land on the guide.
        let root: UIViewController = CommandLine.arguments.contains("-preview")
            ? KeyboardPreviewViewController()
            : RootViewController()
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UINavigationController(rootViewController: root)
        window.makeKeyAndVisible()
        self.window = window
    }
}
