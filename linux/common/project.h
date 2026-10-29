// What both frontends say about the input method, in the words of the macOS
// client's Input menu (macos/JdIME/Controller/InputController.swift).
#pragma once

namespace imejd {

/// The release, from core/build.zig.zon; linux/meson.build passes it in.
inline constexpr const char *kVersion = IMEJD_VERSION;
inline constexpr const char *kReleasesPage = "https://github.com/hronro/ime-jd/releases";

/// The menu's first item, followed by kVersion; it opens kReleasesPage.
inline constexpr const char *kMenuAbout = "键道输入法 ";
/// Opens the phrases file. On macOS it opens the editing window, which
/// Linux does not have yet, so a text editor stands in.
inline constexpr const char *kMenuUserDict = "用户自造词…";
inline constexpr const char *kMenuUserDictEnabled = "启用用户自造词";

} // namespace imejd
