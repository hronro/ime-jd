// 键道 as a Fcitx 5 addon: an input method engine loaded into the fcitx5
// process. Each input context gets a Session (common/session.h); the one
// UserDictStore is watched on fcitx5's event loop. 中/英 switching is
// Fcitx 5's own (Left Shift by default), so the engine has no English mode.
#pragma once

// Before Fcitx's headers: 5.0.x's event.h uses uint64_t without including
// it, which newer compilers no longer bring in on their own.
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>

#include <fcitx-utils/event.h>
#include <fcitx/action.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/addonmanager.h>
#include <fcitx/inputcontextproperty.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/instance.h>

#include "session.h"
#include "update.h"
#include "user_dict.h"

namespace imejd {

/// A Session for each input context.
class FcitxState final : public fcitx::InputContextProperty {
public:
    explicit FcitxState(const UserDictStore &store) : session(store) {}

    Session session;
};

/// A menu item whose text and check mark are read when the menu is shown,
/// so they never go stale.
class FcitxMenuItem final : public fcitx::Action {
public:
    std::function<std::string()> text;
    std::function<bool()> checked;
    std::function<void(fcitx::InputContext *)> onActivate;

    std::string shortText(fcitx::InputContext *) const override { return text ? text() : std::string(); }
    std::string icon(fcitx::InputContext *) const override { return {}; }
    bool isChecked(fcitx::InputContext *) const override { return checked && checked(); }
    void activate(fcitx::InputContext *ic) override {
        if (onActivate) {
            onActivate(ic);
        }
    }
};

class FcitxEngine final : public fcitx::InputMethodEngine {
public:
    explicit FcitxEngine(fcitx::Instance *instance);
    ~FcitxEngine() override;

    void keyEvent(const fcitx::InputMethodEntry &entry, fcitx::KeyEvent &keyEvent) override;
    void activate(const fcitx::InputMethodEntry &entry, fcitx::InputContextEvent &event) override;
    void deactivate(const fcitx::InputMethodEntry &entry, fcitx::InputContextEvent &event) override;
    void reset(const fcitx::InputMethodEntry &entry, fcitx::InputContextEvent &event) override;

    /// A click on visible candidate `index`.
    void selectCandidate(fcitx::InputContext &ic, unsigned index);

private:
    FCITX_ADDON_DEPENDENCY_LOADER(notifications, instance_->addonManager());

    void scheduleReload();
    void reload();
    void notify(const std::string &title, const std::string &body);

    fcitx::Instance *instance_;
    UserDictStore store_;
    fcitx::FactoryFor<FcitxState> factory_;
    std::unique_ptr<fcitx::EventSourceIO> watch_;
    std::unique_ptr<fcitx::EventSourceTime> reloadTimer_;
    /// The update check, in the builds that have one.
    std::optional<update::UpdateClient> update_;

    FcitxMenuItem aboutItem_;
    FcitxMenuItem updateItem_;
    FcitxMenuItem autoCheckItem_;
    FcitxMenuItem userDictItem_;
    FcitxMenuItem userDictEnabledItem_;
    FcitxMenuItem userDictStatusItem_;
};

class FcitxEngineFactory final : public fcitx::AddonFactory {
public:
    fcitx::AddonInstance *create(fcitx::AddonManager *manager) override {
        return new FcitxEngine(manager->instance());
    }
};

} // namespace imejd
