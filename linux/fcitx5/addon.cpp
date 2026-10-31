#include "addon.h"

#include <ctime>
#include <utility>
#include <vector>

#include <unistd.h>

#include <fcitx-module/notifications/notifications_public.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/log.h>
#include <fcitx-utils/misc.h>
#include <fcitx/candidatelist.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputpanel.h>
#include <fcitx/statusarea.h>
#include <fcitx/text.h>
#include <fcitx/userinterfacemanager.h>

#include "project.h"

namespace imejd {

namespace {

/// How long a burst of file events settles before the store reloads: one
/// save is several of them.
constexpr uint64_t kReloadDelayUsec = 300 * 1000;

/// The key as the session wants it: the typed character from the normalized
/// key — Shift+1 is `exclam` — and the modifiers as they were held.
KeyInput keyInput(const fcitx::KeyEvent &event) {
    const fcitx::KeySym sym = event.key().sym();
    const fcitx::KeyStates states = event.rawKey().states();
    KeyInput key;
    key.keysym = sym;
    key.unicode = fcitx::Key::keySymToUnicode(sym);
    key.shift = states.test(fcitx::KeyState::Shift);
    key.control = states.test(fcitx::KeyState::Ctrl);
    key.alt = states.test(fcitx::KeyState::Alt);
    key.super = states.test(fcitx::KeyState::Super) || states.test(fcitx::KeyState::Super2) ||
                states.test(fcitx::KeyState::Hyper) || states.test(fcitx::KeyState::Hyper2) ||
                states.test(fcitx::KeyState::Meta);
    return key;
}

class FcitxCandidate final : public fcitx::CandidateWord {
public:
    FcitxCandidate(FcitxEngine &engine, unsigned index, fcitx::Text text)
        : fcitx::CandidateWord(std::move(text)), engine_(engine), index_(index) {}

    void select(fcitx::InputContext *ic) const override { engine_.selectCandidate(*ic, index_); }

private:
    FcitxEngine &engine_;
    unsigned index_;
};

/// One input context, as a session reaches it.
class FcitxHost final : public Host {
public:
    FcitxHost(FcitxEngine &engine, fcitx::InputContext &ic) : engine_(engine), ic_(ic) {}

    void commit(const std::string &text) override {
        ic_.commitString(text);
        showPreedit({});
    }

    void setPreedit(const std::string &text) override { showPreedit(text); }

    void showCandidates(const std::vector<Candidate> &page) override {
        auto list = std::make_unique<fcitx::CommonCandidateList>();
        list->setPageSize(static_cast<int>(Session::pageSize));
        list->setLabels({"1. ", "2. ", "3. ", "4. ", "5. ", "6. ", "7. ", "8. ", "9. "});
        for (unsigned i = 0; i < page.size(); ++i) {
            // The value, followed by its hint in 〔 〕 brackets — as on
            // macOS, Windows and the CLI.
            fcitx::Text text(page[i].value);
            if (!page[i].hint.empty()) {
                text.append(" 〔" + page[i].hint + "〕");
            }
            list->append<FcitxCandidate>(engine_, i, std::move(text));
        }
        list->setGlobalCursorIndex(0);
        ic_.inputPanel().setCandidateList(std::move(list));
        ic_.updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
    }

    void hideCandidates() override {
        ic_.inputPanel().setCandidateList(nullptr);
        ic_.updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
    }

private:
    /// In the application when it can show preedit, in Fcitx's own panel
    /// otherwise.
    void showPreedit(const std::string &letters) {
        fcitx::Text text;
        if (!letters.empty()) {
            text.append(letters, fcitx::TextFormatFlag::Underline);
            text.setCursor(static_cast<int>(letters.size()));
        }
        auto &panel = ic_.inputPanel();
        if (ic_.capabilityFlags().test(fcitx::CapabilityFlag::Preedit)) {
            panel.setClientPreedit(text);
            panel.setPreedit({});
        } else {
            panel.setPreedit(text);
            panel.setClientPreedit({});
        }
        ic_.updatePreedit();
        ic_.updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
    }

    FcitxEngine &engine_;
    fcitx::InputContext &ic_;
};

/// Opens `target`, a URL or a file, the way the desktop opens it.
void openExternally(const std::string &target) { fcitx::startProcess({"xdg-open", target}); }

/// Whether the editor's package is installed.
bool hasEditor() { return access(kEditor, X_OK) == 0; }

} // namespace

FcitxEngine::FcitxEngine(fcitx::Instance *instance)
    : instance_(instance),
      store_(UserDictStore::defaultDirectory(),
             [this](const std::string &title, const std::string &body) { notify(title, body); }),
      factory_([this](fcitx::InputContext &) { return new FcitxState(store_); }) {
    if (!Engine::abiMatches()) {
        FCITX_ERROR() << "键道: jd.h does not match the libjd linked in";
    }
    instance_->inputContextManager().registerProperty("imejdState", &factory_);

    if (store_.watchFd() >= 0) {
        watch_ = instance_->eventLoop().addIOEvent(
            store_.watchFd(), fcitx::IOEventFlag::In, [this](fcitx::EventSourceIO *, int, fcitx::IOEventFlags) {
                if (store_.drainWatch()) {
                    scheduleReload();
                }
                return true;
            });
    }
    reloadTimer_ = instance_->eventLoop().addTimeEvent(CLOCK_MONOTONIC, fcitx::now(CLOCK_MONOTONIC), 0,
                                                       [this](fcitx::EventSourceTime *, uint64_t) {
                                                           store_.reload();
                                                           return true;
                                                       });
    reloadTimer_->setEnabled(false);

    // The menu, as macOS has it, minus the update items: Linux updates come
    // from the package manager.
    aboutItem_.text = [] { return std::string(kMenuAbout) + kVersion; };
    aboutItem_.onActivate = [](fcitx::InputContext *) { openExternally(kReleasesPage); };
    userDictItem_.text = [] { return std::string(kMenuUserDict); };
    userDictItem_.onActivate = [this](fcitx::InputContext *) {
        if (hasEditor()) {
            fcitx::startProcess({kEditor});
        } else if (store_.ensureFile()) {
            openExternally(store_.filePath());
        }
    };
    userDictEnabledItem_.setCheckable(true);
    userDictEnabledItem_.text = [] { return std::string(kMenuUserDictEnabled); };
    userDictEnabledItem_.checked = [this] { return store_.isEnabled(); };
    userDictEnabledItem_.onActivate = [this](fcitx::InputContext *ic) {
        store_.setEnabled(!store_.isEnabled());
        userDictEnabledItem_.update(ic);
    };
    userDictStatusItem_.text = [this] { return store_.statusText(); };

    auto &ui = instance_->userInterfaceManager();
    ui.registerAction("imejd-about", &aboutItem_);
    ui.registerAction("imejd-user-dict", &userDictItem_);
    ui.registerAction("imejd-user-dict-enabled", &userDictEnabledItem_);
    ui.registerAction("imejd-user-dict-status", &userDictStatusItem_);
}

FcitxEngine::~FcitxEngine() = default;

void FcitxEngine::keyEvent(const fcitx::InputMethodEntry &, fcitx::KeyEvent &keyEvent) {
    if (keyEvent.isRelease()) {
        return;
    }
    auto *ic = keyEvent.inputContext();
    // Password fields get the keys as typed.
    if (ic->capabilityFlags().test(fcitx::CapabilityFlag::Password)) {
        return;
    }
    FcitxHost host(*this, *ic);
    if (ic->propertyFor(&factory_)->session.handleKey(keyInput(keyEvent), host)) {
        keyEvent.filterAndAccept();
    }
}

void FcitxEngine::activate(const fcitx::InputMethodEntry &, fcitx::InputContextEvent &event) {
    auto *ic = event.inputContext();
    ic->propertyFor(&factory_)->session.activate();
    auto &status = ic->statusArea();
    for (auto *item : {&aboutItem_, &userDictItem_, &userDictEnabledItem_, &userDictStatusItem_}) {
        status.addAction(fcitx::StatusGroup::InputMethod, item);
    }
}

void FcitxEngine::deactivate(const fcitx::InputMethodEntry &, fcitx::InputContextEvent &event) {
    auto *ic = event.inputContext();
    FcitxHost host(*this, *ic);
    auto &session = ic->propertyFor(&factory_)->session;
    // Switched to another input method: the letters typed so far go in as
    // they are. Focus lost: Fcitx — or the application — has committed the
    // preedit that holds them already, unless the application could not show
    // one and they were in Fcitx's own panel.
    if (event.type() == fcitx::EventType::InputContextSwitchInputMethod ||
        !ic->capabilityFlags().test(fcitx::CapabilityFlag::Preedit)) {
        session.deactivate(host);
    } else {
        session.cancelComposition(host);
    }
}

void FcitxEngine::reset(const fcitx::InputMethodEntry &, fcitx::InputContextEvent &event) {
    // The application asked, typically because its cursor moved. Fcitx's GTK
    // and Qt modules commit their preedit — the letters typed so far — before
    // they ask, so the composition is dropped here, as Fcitx's own engines
    // drop theirs; committing would put the letters in twice.
    auto *ic = event.inputContext();
    FcitxHost host(*this, *ic);
    ic->propertyFor(&factory_)->session.cancelComposition(host);
}

void FcitxEngine::selectCandidate(fcitx::InputContext &ic, unsigned index) {
    FcitxHost host(*this, ic);
    ic.propertyFor(&factory_)->session.selectCandidate(index, host);
}

void FcitxEngine::scheduleReload() {
    reloadTimer_->setTime(fcitx::now(CLOCK_MONOTONIC) + kReloadDelayUsec);
    reloadTimer_->setOneShot();
}

void FcitxEngine::notify(const std::string &title, const std::string &body) {
    if (auto *addon = notifications()) {
        addon->call<fcitx::INotifications::showTip>("imejd-user-dict", "键道", "fcitx-ime-jd", title, body, -1);
    }
}

} // namespace imejd

FCITX_ADDON_FACTORY(imejd::FcitxEngineFactory);
