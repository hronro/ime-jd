// 键道 as an IBus engine: ibus-daemon creates one of these for each input
// context, in this process (main.cpp). Each holds a Session
// (common/session.h) over the process's one UserDictStore.
//
// 中/英 switching is the engine's own, as with ibus-libpinyin and ibus-rime:
// IBus has no switch of its own (GNOME switches input sources with
// Super+Space), and a Chinese IME on GNOME is expected to have one. It is
// Windows' rule (windows/src/input_mode.rs): Shift pressed and released
// alone. In 英 every key goes to the application as typed; the mode shows,
// through the `InputMode` property, in GNOME's top bar and as the tray icon
// of IBus's own panel.
#pragma once

#include <ibus.h>

namespace imejd {
class UserDictStore;

/// The key of the engine's 中/英 property. Panels show the mode from its
/// symbol: GNOME's in the top bar, IBus's own as its tray icon, which the
/// engine's description names this property for.
inline constexpr const char *kInputModeProperty = "InputMode";
} // namespace imejd

G_BEGIN_DECLS

#define IMEJD_TYPE_IBUS_ENGINE (imejd_ibus_engine_get_type())

GType imejd_ibus_engine_get_type(void);

G_END_DECLS

/// The store every engine of this process reads; set before the first
/// engine is created.
void imejd_ibus_engine_set_store(imejd::UserDictStore *store);
