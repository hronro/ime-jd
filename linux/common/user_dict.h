// The Linux client's user dictionary: the phrases file compiled into the blob
// every session's engine reads, rebuilt whenever the file changes — from a
// text editor, from anything — and handed to engines only while the user has
// switched it on (off by default). A port of the macOS client's
// UserDictStore (macos/JdIME/UserDict/UserDictStore.swift); the file is the
// same one every client reads (bindings/swift/UserDictFile.swift).
//
// Both files live in one directory, ~/.config/ime-jd ($XDG_CONFIG_HOME): the
// phrases, 用户自造词.txt, and settings.ini, which holds the switch:
//
//   [UserDict]
//   Enabled=true
//
// There is no blob cache. The process holding the store — fcitx5 itself, or
// the IBus engine's own — runs once per login session, and a build is a
// couple of milliseconds, so the file is read and compiled at start and after
// every change. A line that does not parse is skipped by the engine, so a
// typo costs that line and nothing else. When the file cannot be loaded at
// all — not UTF-8, unreadable, over the engine's caps — the last good
// dictionary stays in use; the failure is kept in lastError() and reported
// once through the failure handler, for a notification.
//
// A context's dictionary is fixed for its lifetime, so the store never
// touches an engine. It bumps generation(), and each session re-creates its
// engine with activeDictionary() at the next moment nothing is composing.
// Everything runs on the framework's main loop.
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

#include "jd.h"

namespace imejd {

/// A compiled user dictionary: the aligned buffer jd_user_dict_build wrote,
/// whose first size() bytes are the blob.
class UserDictBlob {
public:
    /// Compiles `text` (lines of `value<TAB>keys`). Returns nullptr when the
    /// build fails as a whole; `report.status` and `report.line` say why.
    static std::shared_ptr<const UserDictBlob> build(std::string_view text, uint64_t sourceTag,
                                                     jd_user_dict_report &report);
    ~UserDictBlob();

    UserDictBlob(const UserDictBlob &) = delete;
    UserDictBlob &operator=(const UserDictBlob &) = delete;

    const void *data() const { return storage_; }
    size_t size() const { return size_; }
    unsigned entries() const { return entries_; }

private:
    UserDictBlob(void *storage, size_t size, unsigned entries);

    void *storage_;
    size_t size_;
    unsigned entries_;
};

/// The phrases file's format, as every client reads it.
namespace userdict_file {

inline constexpr const char *fileName = "用户自造词.txt";

/// The comment a new file starts with.
std::string header();
/// FNV-1a, 64-bit, over the UTF-8 text: the dictionary's source tag, and
/// how the store tells an unchanged file from an edited one.
uint64_t hash(std::string_view text);
/// Whether `text` is well-formed UTF-8.
bool isUtf8(std::string_view text);

} // namespace userdict_file

class UserDictStore {
public:
    struct LoadError {
        enum class Kind { NotUtf8, Unreadable, Build };

        Kind kind = Kind::Unreadable;
        /// Unreadable: what the system said.
        std::string reason;
        /// Build: jd_user_dict_build's status, and the line it refers to.
        unsigned status = 0;
        unsigned line = 0;

        /// For the user.
        std::string message() const;
    };

    /// Told about a failed load, with a title and a body for a notification.
    using FailureHandler = std::function<void(const std::string &title, const std::string &body)>;

    /// The store for the files in `directory`, which is created when missing,
    /// loaded once.
    explicit UserDictStore(std::string directory, FailureHandler onFailure = {});
    ~UserDictStore();

    UserDictStore(const UserDictStore &) = delete;
    UserDictStore &operator=(const UserDictStore &) = delete;

    /// $XDG_CONFIG_HOME/ime-jd, which is ~/.config/ime-jd by default.
    static std::string defaultDirectory();

    const std::string &directory() const { return directory_; }
    const std::string &filePath() const { return filePath_; }

    /// Bumped whenever activeDictionary() may differ from what an existing
    /// engine was created with.
    uint64_t generation() const { return generation_; }

    /// The user's switch, off until they turn it on. Off means every new
    /// engine reads the built-in dictionary alone, whatever the file holds;
    /// the file is still loaded and watched.
    bool isEnabled() const { return enabled_; }
    /// Turns the switch on or off and saves it. Returns false when it could
    /// not be saved; the switch is then unchanged.
    bool setEnabled(bool enabled);

    /// What an engine created right now should read.
    std::shared_ptr<const UserDictBlob> activeDictionary() const;
    /// The last successfully built dictionary — kept while switched off, and
    /// kept across a failed rebuild.
    const std::shared_ptr<const UserDictBlob> &dictionary() const { return dictionary_; }
    /// The report of the build that produced dictionary().
    const std::optional<jd_user_dict_report> &report() const { return report_; }
    /// Why the most recent reload failed; empty when dictionary() matches the
    /// file.
    const std::optional<LoadError> &lastError() const { return lastError_; }
    /// One line for the input method's menu.
    std::string statusText() const;

    /// Re-reads the switch, and the file, rebuilding when its content
    /// changed. Returns whether activeDictionary() may now differ.
    bool reload();

    /// Creates the phrases file with header(), unless there is one, so a
    /// text editor can open it. Returns whether the file exists now.
    bool ensureFile();

    /// An inotify descriptor watching the directory, for the framework's
    /// event loop to poll; -1 when there is none.
    int watchFd() const { return watchFd_; }
    /// Reads what the descriptor has. Returns true when it concerned the
    /// phrases file or the settings, so the caller should reload() — after a
    /// short delay, since one save is several events.
    bool drainWatch();

private:
    bool readSwitch() const;
    bool loadFile();
    bool fail(LoadError error, std::optional<uint64_t> hash);
    void addWatch();

    std::string directory_;
    std::string filePath_;
    std::string settingsPath_;
    FailureHandler onFailure_;

    uint64_t generation_ = 0;
    bool enabled_ = false;
    std::shared_ptr<const UserDictBlob> dictionary_;
    std::optional<jd_user_dict_report> report_;
    std::optional<LoadError> lastError_;
    /// hash() of the text dictionary_ was built from; empty when there was no
    /// file. An unchanged file costs one hash and nothing more.
    std::optional<uint64_t> builtHash_;
    /// The hash of content that failed to load, so the same bad content is
    /// reported once; empty when the last reload succeeded.
    std::optional<uint64_t> failedHash_;

    int watchFd_ = -1;
    int watchDescriptor_ = -1;
};

} // namespace imejd
