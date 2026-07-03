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
    }
}
