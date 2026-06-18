import Cocoa
import InputMethodKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let connectionName =
            Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String
            ?? "JdIME_Connection"
        server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
    }
}
