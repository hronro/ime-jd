import AppKit

extension NSApplication {
    /// Hand activation back to the app the user came from once `window`, one
    /// of the IME's own windows, has closed and no other is left on screen.
    ///
    /// The IME is an accessory app: opening a window activates it, and
    /// closing the window does not deactivate it. Left frontmost with no
    /// window, it holds the keyboard focus with nowhere for it to go, and
    /// the Input menu's items — which macOS delivers to the frontmost app's
    /// text-input session — reach nothing: choosing 用户自造词… again
    /// after closing its window did nothing until the user clicked into
    /// another app. Hiding the app re-activates the one in line behind it.
    func yieldActivation(afterClosing window: NSWindow) {
        // Once the close has finished, so the closing window no longer counts.
        DispatchQueue.main.async {
            let othersOnScreen = self.windows.contains {
                $0 !== window && $0.isVisible && $0.styleMask.contains(.titled)
            }
            if self.isActive, !othersOnScreen {
                self.hide(nil)
            }
        }
    }
}
