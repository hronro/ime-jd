#include "session.h"

#include "user_dict.h"

namespace imejd {

Session::Session(const UserDictStore &store) : store_(store) {}

Session::~Session() = default;

bool Session::handleKey(const KeyInput &key, Host &host) {
    syncEngine();
    return dispatch(keyAction(key, isComposing()), host);
}

void Session::activate() { syncEngine(); }

void Session::deactivate(Host &host) {
    // End any in-flight composition cleanly when the application loses focus.
    if (isComposing()) {
        commitRaw(host);
    }
    composition_.clear();
    endComposition(host);
}

void Session::commitComposition(Host &host) {
    if (isComposing()) {
        commitRaw(host);
    }
    endComposition(host);
}

void Session::cancelComposition(Host &host) {
    cancel(host);
    endComposition(host);
}

void Session::selectCandidate(unsigned index, Host &host) {
    if (index >= visible_.size()) {
        return;
    }
    commit(visible_[index].value, host);
    endComposition(host);
}

// MARK: - User dictionary

/// Adopts the store's dictionary when it changed since this engine was
/// created. A context's dictionary is fixed for its lifetime, so the swap
/// waits for a moment when nothing is composing: activation, or the next key
/// after a composition ended. Until then the old engine keeps the old
/// dictionary alive, and the session keeps working on it.
void Session::syncEngine() {
    if (engine_ && (engineGeneration_ == store_.generation() || isComposing() || !visible_.empty())) {
        return;
    }
    engine_ = std::make_unique<Engine>(store_.activeDictionary());
    engineGeneration_ = store_.generation();
}

// MARK: - Candidate window

/// Re-reads the visible page and points the engine's anchor at it, which
/// keeps the engine's automatic commits (space, `;`, the literal-byte
/// fallback) resolving to a candidate the user can see.
void Session::refreshCandidates(Host &host) {
    const unsigned total = engine_->optionsCount();
    if (total == 0) {
        visible_.clear();
        pageStart_ = 0;
        host.hideCandidates();
        return;
    }
    if (pageStart_ >= total) {
        pageStart_ = 0;
    }
    engine_->setAnchor(pageStart_);
    visible_ = engine_->readRange(pageStart_, pageSize);
    if (visible_.empty()) {
        host.hideCandidates();
    } else {
        host.showCandidates(visible_);
    }
}

/// Drops the engine's composition and tears down the candidate window.
void Session::endComposition(Host &host) {
    if (engine_) {
        engine_->reset();
    }
    host.hideCandidates();
    visible_.clear();
    pageStart_ = 0;
}

// MARK: - Dispatch

bool Session::dispatch(const KeyAction &action, Host &host) {
    using Kind = KeyAction::Kind;
    switch (action.kind) {
    case Kind::Passthrough:
        return false;

    case Kind::Escape:
        cancel(host);
        endComposition(host);
        return true;

    case Kind::CommitRaw:
        commitRaw(host);
        endComposition(host);
        return true;

    case Kind::Backspace:
        engine_->backspace();
        if (!backspace(host)) {
            endComposition(host);
        } else {
            pageStart_ = 0;
            refreshCandidates(host);
        }
        return true;

    case Kind::PageNext: {
        const unsigned next = pageStart_ + pageSize;
        if (next < engine_->optionsCount()) {
            pageStart_ = next;
            refreshCandidates(host);
        }
        return true;
    }

    case Kind::PagePrev:
        pageStart_ = pageStart_ >= pageSize ? pageStart_ - pageSize : 0;
        refreshCandidates(host);
        return true;

    case Kind::Select:
        if (action.index < visible_.size()) {
            commit(visible_[action.index].value, host);
            endComposition(host);
            return true;
        }
        // No candidate at that slot — fall through to the engine with the
        // digit as a literal byte. The engine treats `1`-`9` as ordinary
        // input (picking candidates is our job, see core/docs/integration.md),
        // so this commits the anchor candidate with the digit appended.
        return dispatchEngineKey(static_cast<char>('1' + action.index), host);

    case Kind::EngineKey:
        return dispatchEngineKey(action.byte, host);
    }
    return false;
}

bool Session::dispatchEngineKey(char byte, Host &host) {
    const KeyResult result = engine_->pressKey(byte);

    if (result.committed) {
        if (isComposing()) {
            commit(result.commit, host);
        } else {
            host.commit(result.commit);
        }
        if (result.optionsCount == 0) {
            endComposition(host);
        } else {
            // Drilled in: committed text plus a fresh composition started by
            // the just-pressed key.
            append(byte, host);
            pageStart_ = 0;
            refreshCandidates(host);
        }
        return true;
    }

    if (result.optionsCount > 0) {
        append(byte, host);
        pageStart_ = 0;
        refreshCandidates(host);
        return true;
    }

    // The engine returned nothing — don't consume the key.
    return false;
}

// MARK: - Composition

void Session::append(char byte, Host &host) {
    composition_ += byte;
    host.setPreedit(composition_);
}

bool Session::backspace(Host &host) {
    if (composition_.empty()) {
        return false;
    }
    composition_.pop_back();
    host.setPreedit(composition_);
    return !composition_.empty();
}

void Session::commit(const std::string &text, Host &host) {
    composition_.clear();
    host.commit(text);
}

void Session::commitRaw(Host &host) {
    if (composition_.empty()) {
        return;
    }
    const std::string letters = std::move(composition_);
    composition_.clear();
    host.commit(letters);
}

void Session::cancel(Host &host) {
    composition_.clear();
    host.setPreedit({});
}

} // namespace imejd
