// The update check of the generic tarball — the Linux counterpart of
// macos/JdIME/Update/ and windows/src/update/. It is built only with
// -Dupdate_check=true, which only the tarball is: distro packages are updated
// by their package managers.
//
// The release feed is GitHub's `releases/latest`, read by the rules every
// self-updating client shares (UpdateFeed.swift, feed.rs, ReleaseFeed.kt):
// compare the release's MAJOR.MINOR.PATCH with the running build, and pick
// the asset release.yml names for this platform — here the tarball,
// `jd-ime-<tag>-linux-<arch>.tar.xz`.
//
// The work is the updater's, ime-jd-update (updater/), a process of its own:
// it reads the feed, records what it found in update.ini beside the user's
// settings, tells the user through the desktop's notifications, and installs
// a release the tarball's own way, its install.sh run as root. What is here
// is shared with it: the feed's rules and that record. And the frontends'
// side, UpdateClient: the menu item, the switch, and the daily check that
// starts the updater.
#pragma once

#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace imejd::update {

/// `releases/latest`: drafts and pre-releases excluded by the endpoint.
inline constexpr const char *kFeedUrl = "https://api.github.com/repos/hronro/ime-jd/releases/latest";
/// Minimum gap between two automatic checks, in seconds.
inline constexpr int64_t kCheckInterval = 24 * 60 * 60;
/// The switch, in settings.ini: on until the user turns it off, as on
/// macOS and Windows.
inline constexpr const char *kSettingsGroup = "Update";
inline constexpr const char *kAutoCheckKey = "CheckAutomatically";

/// A release version, MAJOR.MINOR.PATCH, parsed from a tag (`v0.6.0`) or the
/// version a build carries (`0.6.0`). A `-prerelease` or `+build` suffix is
/// ignored: the feed only reports full releases.
struct Version {
    unsigned major = 0;
    unsigned minor = 0;
    unsigned patch = 0;

    static std::optional<Version> parse(std::string_view text);
    std::string str() const;
    /// `0.0.0`, never a release.
    bool isPlaceholder() const { return major == 0 && minor == 0 && patch == 0; }

    friend bool operator<(const Version &a, const Version &b);
    friend bool operator==(const Version &a, const Version &b);
};

/// One file attached to a release.
struct Asset {
    std::string name;
    std::string url;
    uint64_t size = 0;
    /// Lowercase hex SHA-256 from the feed's `digest` (`sha256:<hex>`), when
    /// GitHub supplied one.
    std::optional<std::string> sha256;
};

/// Whether `tag` names a release: `v` and a version, safe in a file name.
bool isReleaseTag(std::string_view tag);

/// The release's tag; nothing for any other document — an error body such
/// as `{"message": "API rate limit exceeded"}`.
std::optional<std::string> extractTag(std::string_view json);

/// The asset named `name`, when the release has it with a download URL.
std::optional<Asset> extractAsset(std::string_view json, std::string_view name);

/// The release page for `tag`: its notes, and its downloads by hand.
std::string releasePage(std::string_view tag);

/// This machine's arch as release assets name it: `x86_64` or `arm64`;
/// empty for any other, which has no tarball.
std::string_view hostArch();

/// The tarball for `tag` and `arch`, exactly as packaging/build.sh names it.
std::string tarballName(std::string_view tag, std::string_view arch);

/// What the updater is doing, while it runs.
enum class Busy { None, Checking, Downloading, Installing };

/// update.ini: what the updater found, and what it is doing. Written by the
/// updater alone; the frontends read it.
struct State {
    /// Unix seconds of the last check started, successful or not.
    int64_t lastCheck = 0;
    /// The newest release's tag; empty before the first check.
    std::string latest;
    /// The tarball for this machine in that release; empty name when it has
    /// none.
    Asset tarball;
    /// The tag the user was last told about, so each is told once.
    std::string notified;
    /// The tag of the version on disk, as the updater last saw it — newer
    /// than a frontend's own once an update is installed and the framework
    /// not yet restarted.
    std::string installed;
    Busy busy = Busy::None;
    /// The updater's process while busy, so a run that crashed or ended with
    /// the session does not leave the menu saying it is busy.
    int busyPid = 0;

    static State parse(const std::string &text);
    std::string serialize() const;
};

/// The latest release when it is newer than `current`.
std::optional<Version> newerRelease(const State &state, std::string_view current);

/// The frontends' side: the menu item, the switch, and the daily check, each
/// a start of the updater. Everything runs on the framework's main loop.
class UpdateClient {
public:
    /// Starts the updater with these arguments and lets it go.
    using Spawn = std::function<void(const std::vector<std::string> &args)>;

    /// For the files in `directory` (~/.config/ime-jd), with the updater at
    /// `updater` and this build at version `current`.
    UpdateClient(std::string directory, std::string updater, std::string current, Spawn spawn);

    /// Re-reads update.ini and the switch, as after a change in the
    /// directory.
    void refresh();

    /// Starts a check when one is due, at most once per kCheckInterval, and
    /// only while the switch is on. Called whenever 键道 becomes active.
    void checkIfDue();

    /// The menu item: installs the release found, or checks now, telling the
    /// user either way. Nothing while the updater is busy.
    void activate();

    /// The menu item's text, and whether it can be chosen.
    std::string label() const;
    bool sensitive() const;

    bool autoCheck() const { return autoCheck_; }
    /// Turns the switch on or off and saves it. Returns false when it could
    /// not be saved; the switch is then unchanged.
    bool setAutoCheck(bool on);

private:
    Busy busy() const;
    /// The release to offer: newer than this build, and than one installed
    /// since it started.
    std::optional<Version> offered() const;
    /// The version installed since this build started, while the framework
    /// still runs this one.
    std::optional<Version> awaitingRestart() const;

    std::string directory_;
    std::string updater_;
    std::string current_;
    Spawn spawn_;
    State state_;
    bool autoCheck_ = true;
    /// When this process last started a check, so activations in a row do
    /// not start more before the updater has stamped update.ini.
    int64_t lastSpawn_ = 0;
};

} // namespace imejd::update
