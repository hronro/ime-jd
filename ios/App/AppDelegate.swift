import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // `-preview` launch arg jumps straight to the in-app keyboard preview
        // (used for screenshots / QA); normal launches land on the guide.
        let root: UIViewController = CommandLine.arguments.contains("-preview")
            ? KeyboardPreviewViewController()
            : RootViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: root)
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    // `-landscape` QA launch arg forces landscape (for notch / safe-area testing).
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        CommandLine.arguments.contains("-landscape") ? .landscapeRight : .all
    }
}
