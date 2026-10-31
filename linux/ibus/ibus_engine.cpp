#include "ibus_engine.h"

#include <string>
#include <vector>

#include "project.h"
#include "session.h"
#include "user_dict.h"

namespace {

imejd::UserDictStore *g_store = nullptr;

/// One engine's state beside its GObject.
struct EngineState {
    explicit EngineState(const imejd::UserDictStore &store) : session(store) {}

    imejd::Session session;
    /// 英: every key goes to the application as typed.
    bool english = false;
    /// Shift is down and nothing else has happened since it went down, so its
    /// release switches 中 and 英.
    bool shiftAlone = false;
    /// The focused field is a password or a PIN: keys go to it as typed.
    bool password = false;
};

} // namespace

struct ImeJdIBusEngine {
    IBusEngine parent;
    EngineState *state;
};

struct ImeJdIBusEngineClass {
    IBusEngineClass parent;
};

G_DEFINE_TYPE(ImeJdIBusEngine, imejd_ibus_engine, IBUS_TYPE_ENGINE)

void imejd_ibus_engine_set_store(imejd::UserDictStore *store) { g_store = store; }

namespace {

using imejd::kInputModeProperty;
constexpr const char *kAboutProperty = "imejd-about";
constexpr const char *kUserDictProperty = "imejd-user-dict";
constexpr const char *kUserDictEnabledProperty = "imejd-user-dict-enabled";
constexpr const char *kUserDictStatusProperty = "imejd-user-dict-status";

/// Hints are drawn dimmer than the value, as on macOS.
constexpr guint kHintColor = 0x808080;

ImeJdIBusEngine *self(IBusEngine *engine) { return reinterpret_cast<ImeJdIBusEngine *>(engine); }

EngineState &state(IBusEngine *engine) { return *self(engine)->state; }

/// One input context, as a session reaches it.
class IBusHost final : public imejd::Host {
public:
    explicit IBusHost(IBusEngine *engine) : engine_(engine) {}

    void commit(const std::string &text) override {
        ibus_engine_commit_text(engine_, ibus_text_new_from_string(text.c_str()));
        setPreedit({});
    }

    /// In commit mode: when focus moves, the input context is reset, or the
    /// engine is switched, IBus commits the preedit — the letters typed so
    /// far — to the right application itself.
    void setPreedit(const std::string &letters) override {
        IBusText *text = ibus_text_new_from_string(letters.c_str());
        const auto length = static_cast<guint>(g_utf8_strlen(letters.c_str(), -1));
        if (length > 0) {
            ibus_text_append_attribute(text, IBUS_ATTR_TYPE_UNDERLINE, IBUS_ATTR_UNDERLINE_SINGLE, 0, length);
        }
        ibus_engine_update_preedit_text_with_mode(engine_, text, length, length > 0, IBUS_ENGINE_PREEDIT_COMMIT);
    }

    void showCandidates(const std::vector<imejd::Candidate> &page) override {
        IBusLookupTable *table = ibus_lookup_table_new(imejd::Session::pageSize, 0, TRUE, FALSE);
        for (size_t i = 0; i < page.size(); ++i) {
            // The value, followed by its hint in 〔 〕 brackets — as on
            // macOS, Windows and the CLI.
            std::string shown = page[i].value;
            const auto valueLength = static_cast<guint>(g_utf8_strlen(shown.c_str(), -1));
            if (!page[i].hint.empty()) {
                shown += " 〔" + page[i].hint + "〕";
            }
            IBusText *text = ibus_text_new_from_string(shown.c_str());
            const auto length = static_cast<guint>(g_utf8_strlen(shown.c_str(), -1));
            if (length > valueLength) {
                ibus_text_append_attribute(text, IBUS_ATTR_TYPE_FOREGROUND, kHintColor, valueLength, length);
            }
            ibus_lookup_table_append_candidate(table, text);
            const std::string label = std::to_string(i + 1) + ".";
            ibus_lookup_table_append_label(table, ibus_text_new_from_string(label.c_str()));
        }
        ibus_engine_update_lookup_table(engine_, table, TRUE);
    }

    void hideCandidates() override { ibus_engine_hide_lookup_table(engine_); }

private:
    IBusEngine *engine_;
};

/// Opens `uri` the way the desktop opens it.
void openExternally(const char *uri) {
    GError *error = nullptr;
    if (!g_app_info_launch_default_for_uri(uri, nullptr, &error)) {
        g_warning("键道: cannot open %s: %s", uri, error->message);
        g_error_free(error);
    }
}

/// Starts the editor; false when its package is not installed, or it would
/// not start.
bool startEditor() {
    if (!g_file_test(imejd::kEditor, G_FILE_TEST_IS_EXECUTABLE)) {
        return false;
    }
    gchar *argv[] = {const_cast<gchar *>(imejd::kEditor), nullptr};
    GError *error = nullptr;
    if (!g_spawn_async(nullptr, argv, nullptr, G_SPAWN_DEFAULT, nullptr, nullptr, nullptr, &error)) {
        g_warning("键道: cannot start %s: %s", imejd::kEditor, error->message);
        g_error_free(error);
        return false;
    }
    return true;
}

IBusProperty *property(const char *key, IBusPropType type, const std::string &label, gboolean sensitive = TRUE,
                       IBusPropState propState = PROP_STATE_UNCHECKED) {
    return ibus_property_new(key, type, ibus_text_new_from_string(label.c_str()), nullptr, nullptr, sensitive,
                             TRUE, propState, nullptr);
}

// The menu's items that change. A change goes out as an update of its item,
// never as the menu registered again: GNOME's panel takes an engine's menu
// once, when the engine is switched to, and from then on only updates.

IBusProperty *modeProperty(const EngineState &st) {
    IBusProperty *mode = property(kInputModeProperty, PROP_TYPE_NORMAL, st.english ? "英文" : "中文");
    ibus_property_set_symbol(mode, ibus_text_new_from_string(st.english ? "英" : "中"));
    ibus_property_set_tooltip(mode, ibus_text_new_from_string("切换中/英（Shift）"));
    return mode;
}

IBusProperty *userDictEnabledProperty() {
    return property(kUserDictEnabledProperty, PROP_TYPE_TOGGLE, imejd::kMenuUserDictEnabled, TRUE,
                    g_store->isEnabled() ? PROP_STATE_CHECKED : PROP_STATE_UNCHECKED);
}

IBusProperty *userDictStatusProperty() {
    return property(kUserDictStatusProperty, PROP_TYPE_NORMAL, g_store->statusText(), FALSE);
}

/// The menu, as macOS has it minus the update items (Linux updates come from
/// the package manager), after the 中/英 switch.
void registerProperties(IBusEngine *engine) {
    IBusPropList *list = ibus_prop_list_new();
    ibus_prop_list_append(list, modeProperty(state(engine)));
    ibus_prop_list_append(list, property(kAboutProperty, PROP_TYPE_NORMAL, std::string(imejd::kMenuAbout) +
                                                                                imejd::kVersion));
    ibus_prop_list_append(list, property(kUserDictProperty, PROP_TYPE_NORMAL, imejd::kMenuUserDict));
    ibus_prop_list_append(list, userDictEnabledProperty());
    ibus_prop_list_append(list, userDictStatusProperty());
    ibus_engine_register_properties(engine, list);
}

/// Brings the changing items up to date: the mode, which is this input
/// context's, and the user dictionary's switch and status, which a reload of
/// the file may have changed.
void updateProperties(IBusEngine *engine) {
    ibus_engine_update_property(engine, modeProperty(state(engine)));
    ibus_engine_update_property(engine, userDictEnabledProperty());
    ibus_engine_update_property(engine, userDictStatusProperty());
}

/// The whole menu for the panels that take it each time, and its changing
/// items for GNOME's, which may hold it from another input context.
void showProperties(IBusEngine *engine) {
    registerProperties(engine);
    updateProperties(engine);
}

/// Switches 中 and 英. The letters typed so far go in as they are, as on
/// Windows.
void toggleMode(IBusEngine *engine) {
    EngineState &st = state(engine);
    st.english = !st.english;
    if (st.english) {
        IBusHost host(engine);
        st.session.commitComposition(host);
    }
    ibus_engine_update_property(engine, modeProperty(st));
}

gboolean processKeyEvent(IBusEngine *engine, guint keyval, guint /*keycode*/, guint modifiers) {
    EngineState &st = state(engine);
    const bool release = modifiers & IBUS_RELEASE_MASK;
    constexpr guint chords = IBUS_CONTROL_MASK | IBUS_MOD1_MASK | IBUS_SUPER_MASK | IBUS_HYPER_MASK |
                             IBUS_META_MASK | IBUS_MOD4_MASK;

    // Shift pressed and released alone switches 中 and 英. Shift is everyday
    // for capitals and selections, so a press counts only when nothing else
    // happened before the release; Shift itself always reaches the
    // application.
    if (keyval == IBUS_KEY_Shift_L || keyval == IBUS_KEY_Shift_R) {
        if (!release) {
            st.shiftAlone = !(modifiers & chords);
            return FALSE;
        }
        if (!st.shiftAlone) {
            return FALSE;
        }
        st.shiftAlone = false;
        toggleMode(engine);
        return TRUE;
    }
    if (!release) {
        st.shiftAlone = false;
    }

    if (release || st.english || st.password) {
        return FALSE;
    }

    imejd::KeyInput key;
    key.keysym = keyval;
    key.unicode = ibus_keyval_to_unicode(keyval);
    key.shift = modifiers & IBUS_SHIFT_MASK;
    key.control = modifiers & IBUS_CONTROL_MASK;
    key.alt = modifiers & IBUS_MOD1_MASK;
    key.super = modifiers & (IBUS_SUPER_MASK | IBUS_HYPER_MASK | IBUS_META_MASK | IBUS_MOD4_MASK);
    IBusHost host(engine);
    return st.session.handleKey(key, host);
}

void focusIn(IBusEngine *engine) {
    state(engine).session.activate();
    showProperties(engine);
}

// Focus out, reset and disable: IBus has just committed the preedit, the
// letters typed so far, to the application it belongs to (see setPreedit),
// so the session only lets go. Committing them here instead would send them
// wherever the engine's focus has gone — the next application, when IBus
// shares one engine among all of them.

void focusOut(IBusEngine *engine) {
    IBusHost host(engine);
    state(engine).session.cancelComposition(host);
}

void reset(IBusEngine *engine) {
    IBusHost host(engine);
    state(engine).session.cancelComposition(host);
}

void enable(IBusEngine *engine) {
    // Every context starts in 中, as Windows' Chinese IMEs do.
    state(engine).english = false;
    state(engine).session.activate();
    showProperties(engine);
}

void disable(IBusEngine *engine) {
    IBusHost host(engine);
    state(engine).session.cancelComposition(host);
}

void setContentType(IBusEngine *engine, guint purpose, guint /*hints*/) {
    EngineState &st = state(engine);
    st.password = purpose == IBUS_INPUT_PURPOSE_PASSWORD || purpose == IBUS_INPUT_PURPOSE_PIN;
    if (st.password) {
        IBusHost host(engine);
        st.session.commitComposition(host);
    }
}

void candidateClicked(IBusEngine *engine, guint index, guint /*button*/, guint /*state*/) {
    IBusHost host(engine);
    state(engine).session.selectCandidate(index, host);
}

void propertyActivate(IBusEngine *engine, const gchar *name, guint propState) {
    const std::string key = name;
    if (key == kInputModeProperty) {
        toggleMode(engine);
    } else if (key == kAboutProperty) {
        openExternally(imejd::kReleasesPage);
    } else if (key == kUserDictProperty) {
        if (!startEditor() && g_store->ensureFile()) {
            gchar *uri = g_filename_to_uri(g_store->filePath().c_str(), nullptr, nullptr);
            if (uri) {
                openExternally(uri);
                g_free(uri);
            }
        }
    } else if (key == kUserDictEnabledProperty) {
        g_store->setEnabled(propState == PROP_STATE_CHECKED);
        updateProperties(engine);
    }
}

void finalize(GObject *object) {
    delete self(IBUS_ENGINE(object))->state;
    G_OBJECT_CLASS(imejd_ibus_engine_parent_class)->finalize(object);
}

} // namespace

static void imejd_ibus_engine_init(ImeJdIBusEngine *engine) { engine->state = new EngineState(*g_store); }

static void imejd_ibus_engine_class_init(ImeJdIBusEngineClass *klass) {
    G_OBJECT_CLASS(klass)->finalize = finalize;
    IBusEngineClass *engine = IBUS_ENGINE_CLASS(klass);
    engine->process_key_event = processKeyEvent;
    engine->focus_in = focusIn;
    engine->focus_out = focusOut;
    engine->reset = reset;
    engine->enable = enable;
    engine->disable = disable;
    engine->set_content_type = setContentType;
    engine->candidate_clicked = candidateClicked;
    engine->property_activate = propertyActivate;
}
