// What both frontends say about the input method, in the words of the macOS
// client's Input menu (macos/JdIME/Controller/InputController.swift).
#pragma once

namespace imejd {

/// The release, from core/build.zig.zon; linux/meson.build passes it in.
inline constexpr const char *kVersion = IMEJD_VERSION;
inline constexpr const char *kReleasesPage = "https://github.com/hronro/ime-jd/releases";

/// The user-dictionary editor, a package of its own (editor/); meson.build
/// passes in where it installs.
inline constexpr const char *kEditor = IMEJD_EDITOR;

/// The update check's process, in the builds that have one: the generic
/// tarball's (update.h). Distro packages are updated by their package
/// managers, and their menus have no update items.
#ifdef IMEJD_UPDATER
inline constexpr const char *kUpdater = IMEJD_UPDATER;
#else
inline constexpr const char *kUpdater = nullptr;
#endif

/// The menu's first item, followed by kVersion; it opens kReleasesPage.
inline constexpr const char *kMenuAbout = "键道输入法 ";
/// With kUpdater, the update item follows, its text UpdateClient's, and then
/// its switch.
inline constexpr const char *kMenuAutoCheck = "自动检查更新";
/// Opens kEditor, as macOS opens its window; without it, the phrases file
/// in a text editor.
inline constexpr const char *kMenuUserDict = "用户自造词…";
inline constexpr const char *kMenuUserDictEnabled = "启用用户自造词";

} // namespace imejd
