// The files in ~/.config/ime-jd: reading them, replacing them in one rename,
// and the lenient INI handling of settings.ini, every line a reader does not
// understand kept as it was — the editor and the update check keep settings
// of their own in the same file.
#pragma once

#include <optional>
#include <string>
#include <string_view>

namespace imejd {

/// The directory's settings: the user dictionary's switch, the update
/// check's, and the editor's window size.
inline constexpr const char *kSettingsName = "settings.ini";
/// The update check's record of what it found and what it is doing
/// (update.h), which the menus show.
inline constexpr const char *kUpdateStateName = "update.ini";

namespace files {

/// ~/.config/ime-jd: under $XDG_CONFIG_HOME when that is an absolute path,
/// ~/.config otherwise.
std::string configDirectory();
/// ~/.cache/ime-jd, by the same rule with $XDG_CACHE_HOME.
std::string cacheDirectory();

/// The value of `key` in `[group]`, in the INI format GLib's GKeyFile reads.
std::optional<std::string> iniValue(const std::string &content, std::string_view group, std::string_view key);

/// `content` with `key` in `[group]` set to `value`, every other line as it
/// was.
std::string withIniValue(const std::string &content, std::string_view group, std::string_view key,
                         std::string_view value);

/// Creates `path` and its parents. XDG asks for 0700 on directories created
/// on the user's behalf.
void makeDirectories(const std::string &path);

/// The file's bytes, or nothing when there is no file. Returns 0, or the
/// errno that kept it from being read.
int readFile(const std::string &path, std::optional<std::string> &out);

/// Writes all of `content` to `fd`.
bool writeAll(int fd, std::string_view content);

/// Replaces `path` with `content` in one rename, so a reader never sees half
/// a file.
bool writeFileAtomically(const std::string &path, std::string_view content);

} // namespace files
} // namespace imejd
