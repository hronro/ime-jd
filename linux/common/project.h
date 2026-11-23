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
/// Opens kEditor's 编码反查 window (--lookup), as macOS opens its own. The
/// editor's package has it; without it, a notification says what to
/// install, as there is nothing else to open.
inline constexpr const char *kMenuLookup = "编码反查…";
inline constexpr const char *kLookupArgument = "--lookup";
/// What brings the window: the editor's package, or — the generic tarball,
/// whose install.sh leaves the editor out where GTK 4 is missing — GTK 4
/// and the tarball's install.sh again. The title says it, as desktops cut a
/// notification's body short.
inline constexpr const char *kLookupUnavailableTitle =
    kUpdater ? "编码反查需要 GTK 4" : "编码反查需要安装 ime-jd-userdict";
inline constexpr const char *kLookupUnavailableDetail =
    kUpdater ? "编码反查的窗口需要 GTK 4。从发行版装上 GTK 4 后，重新运行通用压缩包中的 install.sh 即可使用。"
             : "编码反查的窗口在 ime-jd-userdict 软件包中，用软件包管理器安装它即可使用（AUR 中为 "
               "ime-jd-userdict-bin）。";
/// Opens kEditor, as macOS opens its window; without it, the phrases file
/// in a text editor.
inline constexpr const char *kMenuUserDict = "用户自造词…";
inline constexpr const char *kMenuUserDictEnabled = "启用用户自造词";
/// The second switch, usable only while the first is on.
inline constexpr const char *kMenuUserDictOnly = "忽略内置词库";

} // namespace imejd
