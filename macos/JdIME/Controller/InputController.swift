import AppKit
import InputMethodKit

@objc(JdIME_InputController)
final class InputController: IMKInputController {
    /// Candidates shown per panel page. Purely a display choice — the engine
    /// addresses candidates by flat index and has no page concept — so the page
    /// arithmetic lives here. 9 matches IMK's per-line element cap and the
    /// panel's 1-9 number labels (see Candidates.swift).
    private static let pageSize: UInt32 = 9

    /// Re-created when the user dictionary changes; see syncEngine().
    private var engine = Engine(userDict: UserDictStore.shared.activeDictionary)
    private var engineGeneration = UserDictStore.shared.generation
    private let composition = Composition()
    private var candidatePanel: Candidates?

    /// The candidates currently on screen.
    private var visible: [Candidate] = []
    /// Flat index of the first visible candidate; always a multiple of
    /// `pageSize`.
    private var pageStart: UInt32 = 0

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        if let server = server {
            self.candidatePanel = Candidates(server: server)
        }
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event, event.type == .keyDown else { return false }
        guard let client = sender as? IMKTextInput else { return false }

        syncEngine()
        let action = keyAction(event: event, isComposing: composition.isActive)
        return dispatch(action: action, client: client)
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    override func activateServer(_ sender: Any!) {
        // Activation is the one moment we know the IME is actually in use,
        // and nothing is composing yet: adopt an edited user dictionary, and
        // run the daily update check (a single defaults read when nothing is
        // due).
        syncEngine()
        UpdateManager.shared.checkIfDue()
    }

    override func deactivateServer(_ sender: Any!) {
        // End any in-flight composition cleanly when the host loses focus.
        if let client = sender as? IMKTextInput {
            if composition.isActive {
                composition.commitRaw(client: client)
            }
        }
        composition.reset()
        endComposition()
    }

    override func commitComposition(_ sender: Any!) {
        guard let client = sender as? IMKTextInput else { return }
        if composition.isActive {
            composition.commitRaw(client: client)
        }
        endComposition()
    }

    override func cancelComposition() {
        if let client = self.client() {
            composition.cancel(client: client)
        }
        endComposition()
    }

    // MARK: - Input menu

    /// The IME's section of the Input menu (the menu-bar input-source
    /// dropdown). IMK asks for this every time the menu opens, so the items
    /// can reflect live state: the version, an update the daily check found,
    /// a check or download in flight, the auto-check toggle, and the user
    /// dictionary's toggle and status. Items with a nil action are the
    /// disabled status lines.
    override func menu() -> NSMenu! {
        let updates = UpdateManager.shared
        let menu = NSMenu(title: "键道")

        let version = updates.currentVersion.map(String.init(describing:)) ?? "0.0.0"
        menu.addItem(menuItem("键道输入法 \(version)", #selector(openReleasePage(_:))))

        switch updates.phase {
        case .checking:
            menu.addItem(menuItem("正在检查更新…", nil))
        case .downloading:
            menu.addItem(menuItem("正在下载安装包…", nil))
        case .idle:
            menu.addItem(menuItem("检查更新…", #selector(checkForUpdates(_:))))
            if let update = updates.availableUpdate {
                menu.addItem(menuItem("发现新版本 \(update.tag)，下载并安装…", #selector(installUpdate(_:))))
            }
        }

        menu.addItem(.separator())
        let autoCheck = menuItem("自动检查更新", #selector(toggleAutoCheck(_:)))
        autoCheck.state = updates.isAutoCheckEnabled ? .on : .off
        menu.addItem(autoCheck)

        menu.addItem(.separator())
        let store = UserDictStore.shared
        menu.addItem(menuItem("用户自造词…", #selector(openUserDictWindow(_:))))
        let userDict = menuItem("启用用户自造词", #selector(toggleUserDict(_:)))
        userDict.state = store.isEnabled ? .on : .off
        menu.addItem(userDict)
        menu.addItem(menuItem(store.statusText, nil))
        return menu
    }

    /// Items keep a nil target: IMK renders the menu in the text-input menu
    /// agent and, on selection, sends the action to this controller — the
    /// pattern the IMK header documents and every open-source IMK IME uses.
    private func menuItem(_ title: String, _ action: Selector?) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: "")
    }

    @objc private func openReleasePage(_ sender: Any?) {
        UpdateManager.shared.open(UpdateFeed.releasesPageURL)
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        UpdateManager.shared.checkNow()
    }

    @objc private func installUpdate(_ sender: Any?) {
        UpdateManager.shared.downloadAndInstall()
    }

    @objc private func toggleAutoCheck(_ sender: Any?) {
        UpdateManager.shared.isAutoCheckEnabled.toggle()
    }

    @objc private func toggleUserDict(_ sender: Any?) {
        UserDictStore.shared.isEnabled.toggle()
    }

    @objc private func openUserDictWindow(_ sender: Any?) {
        UserDictWindowController.shared.show()
    }

    // MARK: - User dictionary

    /// Adopt the store's dictionary when it changed since this engine was
    /// created. A context's dictionary is fixed for its lifetime, and the
    /// candidates on screen point into the old blob, so the swap waits for a
    /// moment when nothing is composing: activation, or the next key after a
    /// composition ended. Until then the old engine keeps the old dictionary
    /// alive, and the IME keeps working on it.
    private func syncEngine() {
        let store = UserDictStore.shared
        guard engineGeneration != store.generation,
              !composition.isActive, visible.isEmpty
        else { return }
        engine = Engine(userDict: store.activeDictionary)
        engineGeneration = store.generation
    }

    // MARK: - IMKCandidates callbacks

    override func candidates(_ sender: Any!) -> [Any]! {
        visible.map { CandidateFormatter.display($0) }
    }

    override func candidateSelected(_ candidateString: NSAttributedString!) {
        guard let client = self.client() else { return }
        // The panel hands back the *displayed* string (value + 〔hint〕), so map
        // it back to the candidate's committable value — a click should commit
        // 你, not 你 〔…〕. A collision here would need two candidates with the
        // same value AND the same hint, in which case either one commits
        // identical text, so the round-trip is sound.
        let shown = candidateString?.string ?? ""
        let value = visible.first {
            CandidateFormatter.display($0).string == shown
        }?.value ?? shown
        composition.commit(text: value, client: client)
        endComposition()
    }

    override func candidateSelectionChanged(_ candidateString: NSAttributedString!) {
        // No-op; engine drives selection.
    }

    // MARK: - Candidate window

    /// Re-read the visible page and point the engine's anchor at it.
    ///
    /// Pointing the anchor first is what keeps the engine's *automatic* commits
    /// (space, `;`, the literal-byte fallback) resolving to a candidate the user
    /// can actually see. Reads themselves are pure, so nothing else needs
    /// restoring afterwards.
    private func refreshCandidates() {
        let total = engine.state.optionsCount
        guard total > 0 else {
            visible = []
            pageStart = 0
            candidatePanel?.hide()
            return
        }
        if pageStart >= total { pageStart = 0 }
        engine.setAnchor(pageStart)
        visible = engine.readRange(from: pageStart, count: Int(Self.pageSize))
        if visible.isEmpty {
            candidatePanel?.hide()
        } else {
            candidatePanel?.show()
        }
    }

    /// Drop the engine's composition and tear down the candidate window.
    private func endComposition() {
        engine.reset()
        candidatePanel?.hide()
        visible = []
        pageStart = 0
    }

    // MARK: - Dispatch

    private func dispatch(action: KeyAction, client: IMKTextInput) -> Bool {
        switch action {
        case .passthrough:
            return false

        case .escape:
            composition.cancel(client: client)
            endComposition()
            return true

        case .commitRaw:
            composition.commitRaw(client: client)
            endComposition()
            return true

        case .backspace:
            engine.backspace()
            let stillComposing = composition.backspace(client: client)
            if !stillComposing {
                endComposition()
            } else {
                pageStart = 0
                refreshCandidates()
            }
            return true

        case .pageNext:
            let next = pageStart + Self.pageSize
            if next < engine.state.optionsCount {
                pageStart = next
                refreshCandidates()
            }
            return true

        case .pagePrev:
            pageStart = pageStart >= Self.pageSize ? pageStart - Self.pageSize : 0
            refreshCandidates()
            return true

        case .selectIdx(let idx):
            if idx < visible.count {
                composition.commit(text: visible[idx].value, client: client)
                endComposition()
                return true
            }
            // No candidate at that slot — fall through to the engine with
            // the digit as a literal byte. The engine treats `1`-`9` as
            // ordinary literal input (it does NOT pick from candidates;
            // that's our job — see core/docs/integration.md), so we end
            // up with the anchor candidate + digit appended via the
            // engine's commit-and-append path. Matches windows/src/tip.rs.
            let digitByte = UInt8(0x31 + idx)
            return dispatchEngineKey(byte: digitByte, client: client)

        case .engineKey(let byte):
            return dispatchEngineKey(byte: byte, client: client)
        }
    }

    private func dispatchEngineKey(byte: UInt8, client: IMKTextInput) -> Bool {
        let state = engine.pressKey(byte)

        if let commit = state.commit {
            if composition.isActive {
                composition.commit(text: commit, client: client)
            } else {
                client.insertText(
                    commit,
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
            }
            if state.optionsCount == 0 {
                endComposition()
            } else {
                // Drilled in: committed text plus a fresh composition started
                // by the just-pressed key.
                composition.append(byte, client: client)
                pageStart = 0
                refreshCandidates()
            }
            return true
        }

        if state.optionsCount > 0 {
            composition.append(byte, client: client)
            pageStart = 0
            refreshCandidates()
            return true
        }

        // Engine returned nothing — don't consume the key.
        return false
    }
}
