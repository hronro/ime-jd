import AppKit

/// 编码反查: a small window, opened from the Input menu, that asks for a word
/// and shows the codes that type it — libjd's `jd_lookup_codes` over the
/// built-in tables and, while it is switched on, the user dictionary, the
/// same dictionaries the IME types with.
///
/// A plain window in the IME process, like the user dictionary's, rather
/// than an app-modal `NSAlert.runModal`: InputMethodKit serves the IME's own
/// windows, so the word can be typed here with 键道 itself, and that is
/// known to work for an ordinary window. The result is a sheet on the
/// window, which does not run a modal loop either; dismissing it leaves the
/// word selected for the next query.
final class CodeLookupWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = CodeLookupWindowController()

    private let field = NSTextField()
    private let lookUpButton = NSButton(title: "查询", target: nil, action: nil)

    init() {
        let window = CodeLookupWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "编码反查"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    private func buildContent(in window: NSWindow) {
        let content = NSView()
        window.contentView = content

        let prompt = NSTextField(wrappingLabelWithString: "输入或粘贴要查询的词：")
        field.placeholderString = "例如：键道"
        field.delegate = self
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true

        let close = NSButton(title: "关闭", target: self, action: #selector(closeWindow(_:)))
        close.keyEquivalent = "\u{1b}"
        lookUpButton.target = self
        lookUpButton.action = #selector(lookUp(_:))
        lookUpButton.keyEquivalent = "\r"
        lookUpButton.isEnabled = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, close, lookUpButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [prompt, field, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: field)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    // MARK: - Showing

    /// Open the window with an empty field, or bring an open one forward
    /// with its word selected, so typing or pasting replaces it. The field
    /// is emptied here rather than on close: closing mid-composition makes
    /// 键道 commit the typed keys into the field as the window goes.
    func show() {
        if window?.isVisible != true {
            field.stringValue = ""
            lookUpButton.isEnabled = false
        }
        // We are an accessory app; without this the window opens behind the
        // frontmost app's windows.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        focusField()
    }

    func windowWillClose(_ notification: Notification) {
        if let window { NSApp.yieldActivation(afterClosing: window) }
    }

    private func focusField() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    // MARK: - Actions

    @objc private func lookUp(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        let query = CodeLookupReport.query(from: field.stringValue)
        guard !query.isEmpty else { return }

        // A fresh engine over what the IME types with right now: the user
        // dictionary only while it is switched on. Cheap — one allocation
        // and a validation pass over the user's phrases — and it is gone
        // when this returns; the codes are plain strings.
        let store = UserDictStore.shared
        let codes = Engine(userDict: store.activeDictionary).lookupCodes(query)
        let report = CodeLookupReport(query: query, codes: codes, userDictEnabled: store.isEnabled)

        let alert = NSAlert()
        alert.messageText = report.title
        alert.informativeText = report.body
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.focusField()
        }
    }

    @objc private func closeWindow(_ sender: Any?) {
        window?.performClose(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        lookUpButton.isEnabled = !CodeLookupReport.query(from: field.stringValue).isEmpty
    }
}

/// The IME is an accessory app with no main menu, so nothing would turn
/// ⌘V and friends into the editing actions an Edit menu sends; without
/// this, pasting a word needs the field's context menu. Sent down the
/// responder chain to the field's editor.
private final class CodeLookupWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let action: Selector?
        switch (flags, event.charactersIgnoringModifiers) {
        case (.command, "x"): action = #selector(NSText.cut(_:))
        case (.command, "c"): action = #selector(NSText.copy(_:))
        case (.command, "v"): action = #selector(NSText.paste(_:))
        case (.command, "a"): action = #selector(NSText.selectAll(_:))
        case (.command, "z"): action = Selector(("undo:"))
        case ([.command, .shift], "z"), ([.command, .shift], "Z"): action = Selector(("redo:"))
        case (.command, "w"): action = #selector(NSWindow.performClose(_:))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
