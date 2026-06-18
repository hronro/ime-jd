import AppKit
import InputMethodKit

final class Composition {
    private(set) var buffer: String = ""

    var isActive: Bool { !buffer.isEmpty }

    func append(_ byte: UInt8, client: IMKTextInput) {
        guard let scalar = Unicode.Scalar(UInt32(byte)) else { return }
        buffer.append(Character(scalar))
        updateMarkedText(client: client)
    }

    /// Returns `true` if there is still preedit text after the backspace.
    @discardableResult
    func backspace(client: IMKTextInput) -> Bool {
        guard !buffer.isEmpty else { return false }
        buffer.removeLast()
        if buffer.isEmpty {
            clearMarkedText(client: client)
            return false
        }
        updateMarkedText(client: client)
        return true
    }

    func commit(text: String, client: IMKTextInput) {
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        buffer.removeAll(keepingCapacity: true)
    }

    func commitRaw(client: IMKTextInput) {
        guard !buffer.isEmpty else { return }
        let out = buffer
        buffer.removeAll(keepingCapacity: true)
        client.insertText(out, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func cancel(client: IMKTextInput) {
        buffer.removeAll(keepingCapacity: true)
        clearMarkedText(client: client)
    }

    func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    // MARK: - Marked text

    private func updateMarkedText(client: IMKTextInput) {
        let attrs: [NSAttributedString.Key: Any] = [
            .underlineStyle: NSUnderlineStyle.thick.rawValue,
            NSAttributedString.Key("NSMarkedClauseSegment"): 0,
        ]
        let attributed = NSAttributedString(string: buffer, attributes: attrs)
        client.setMarkedText(
            attributed,
            selectionRange: NSRange(location: buffer.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    private func clearMarkedText(client: IMKTextInput) {
        let empty = NSAttributedString(string: "")
        client.setMarkedText(
            empty,
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }
}
