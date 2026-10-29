// One input context's typing: the engine, the letters typed so far (shown
// as preedit), and the page of candidates on screen. A port of the macOS
// client's InputController and Composition (macos/JdIME/Controller/), with
// the framework's side behind Host, so the Fcitx 5 addon and the IBus engine
// share everything but the calls that reach the application.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "engine.h"
#include "key_gate.h"

namespace imejd {

class UserDictStore;

/// What a frontend does to its input context when a session asks.
class Host {
public:
    virtual ~Host() = default;

    /// Inserts `text` into the application, ending any preedit.
    virtual void commit(const std::string &text) = 0;
    /// Shows the letters typed so far as preedit; empty clears it.
    virtual void setPreedit(const std::string &text) = 0;
    /// Shows a page of candidates, labelled 1 to 9, the first one
    /// highlighted: it is what space commits.
    virtual void showCandidates(const std::vector<Candidate> &page) = 0;
    virtual void hideCandidates() = 0;
};

class Session {
public:
    /// Candidates shown per page. Purely a display choice — the engine
    /// addresses candidates by flat index and has no page concept — matching
    /// the 1-9 selector keys.
    static constexpr unsigned pageSize = 9;

    explicit Session(const UserDictStore &store);
    ~Session();

    Session(const Session &) = delete;
    Session &operator=(const Session &) = delete;

    /// A key press. Returns whether the session consumed it; one it did not
    /// goes on to the application.
    bool handleKey(const KeyInput &key, Host &host);
    /// The input method became active here, and nothing is composing yet:
    /// the moment to adopt an edited user dictionary.
    void activate();
    /// Focus left, or the input method was switched away: the letters typed
    /// so far go in as they are.
    void deactivate(Host &host);
    /// The application asked for the composition to be finished: the
    /// letters typed so far go in as they are.
    void commitComposition(Host &host);
    /// The composition ends without the session committing anything: the
    /// framework commits the preedit, which holds the letters typed so far,
    /// itself — routed to the right application, which an engine cannot do
    /// once focus has moved on.
    void cancelComposition(Host &host);
    /// A click on visible candidate `index`.
    void selectCandidate(unsigned index, Host &host);

    bool isComposing() const { return !composition_.empty(); }
    const std::vector<Candidate> &visible() const { return visible_; }

private:
    void syncEngine();
    bool dispatch(const KeyAction &action, Host &host);
    bool dispatchEngineKey(char byte, Host &host);
    void refreshCandidates(Host &host);
    void endComposition(Host &host);

    // The composition: the raw letters typed so far.
    void append(char byte, Host &host);
    /// Returns whether there is still something composing.
    bool backspace(Host &host);
    void commit(const std::string &text, Host &host);
    void commitRaw(Host &host);
    void cancel(Host &host);

    const UserDictStore &store_;
    /// Created at the first key; re-created when the user dictionary changes,
    /// see syncEngine().
    std::unique_ptr<Engine> engine_;
    uint64_t engineGeneration_ = 0;
    std::string composition_;
    /// The candidates currently on screen.
    std::vector<Candidate> visible_;
    /// Flat index of the first visible candidate; always a multiple of
    /// pageSize.
    unsigned pageStart_ = 0;
};

} // namespace imejd
