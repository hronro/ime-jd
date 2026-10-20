import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    // No window here: the app runs the UIScene life cycle (see Info.plist),
    // and SceneDelegate builds the window.

    // `-landscape` QA launch arg forces landscape (for notch / safe-area testing).
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        CommandLine.arguments.contains("-landscape") ? .landscapeRight : .all
    }
}
