import Cocoa
import InputMethodKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The fallback mirrors Info.plist's InputMethodConnectionName, which
        // must stay "<bundle-id>_Connection" — see the comment there.
        let connectionName =
            Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String
            ?? "com.hronro.ime-jd_Connection"
        server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)

        // Update notifications must find their delegate before one can be
        // clicked; the daily check itself also runs on every activation
        // (InputController.activateServer), this just covers a long-lived
        // process that is never re-activated.
        UpdateManager.shared.installNotificationDelegate()
        UpdateManager.shared.checkIfDue()
    }
}
