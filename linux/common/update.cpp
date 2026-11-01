#include "update.h"

#include <charconv>
#include <ctime>
#include <utility>

#include "files.h"

namespace imejd::update {

namespace {

constexpr auto npos = std::string_view::npos;

// ---- A scanner over the feed's JSON ----------------------------------------
//
// Just enough to walk objects and arrays and read the strings and numbers
// the updater needs, member by member, so a key of a nested object — an
// asset's uploader has a `name` of its own — is never mistaken for one of
// its parent's. Malformed input, or nesting deeper than any feed has, reads
// as nothing.

constexpr int kMaxDepth = 32;

using Members = std::vector<std::pair<std::string, std::string_view>>;

size_t skipSpace(std::string_view s, size_t i) {
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')) {
        ++i;
    }
    return i;
}

/// Past the string starting at `i`, a quote.
size_t skipString(std::string_view s, size_t i) {
    for (++i; i < s.size(); ++i) {
        if (s[i] == '\\') {
            ++i;
        } else if (s[i] == '"') {
            return i + 1;
        }
    }
    return npos;
}

/// Past the value starting at `i`.
size_t skipValue(std::string_view s, size_t i, int depth) {
    i = skipSpace(s, i);
    if (i >= s.size() || depth > kMaxDepth) {
        return npos;
    }
    const char open = s[i];
    if (open == '"') {
        return skipString(s, i);
    }
    if (open == '{' || open == '[') {
        const char close = open == '{' ? '}' : ']';
        i = skipSpace(s, i + 1);
        if (i < s.size() && s[i] == close) {
            return i + 1;
        }
        for (;;) {
            if (open == '{') {
                if (i >= s.size() || s[i] != '"' || (i = skipString(s, i)) == npos) {
                    return npos;
                }
                i = skipSpace(s, i);
                if (i >= s.size() || s[i] != ':') {
                    return npos;
                }
                ++i;
            }
            if ((i = skipValue(s, i, depth + 1)) == npos) {
                return npos;
            }
            i = skipSpace(s, i);
            if (i >= s.size()) {
                return npos;
            }
            if (s[i] == close) {
                return i + 1;
            }
            if (s[i] != ',') {
                return npos;
            }
            i = skipSpace(s, i + 1);
        }
    }
    // A number or a literal, up to the next delimiter.
    size_t end = i;
    while (end < s.size() && std::string_view(",}] \t\r\n").find(s[end]) == npos) {
        ++end;
    }
    return end == i ? npos : end;
}

/// A string's text, with the simple escapes undone. Nothing for any other
/// escape or a control character: none of the strings read here need one.
std::optional<std::string> stringValue(std::string_view value) {
    if (value.size() < 2 || value.front() != '"' || value.back() != '"') {
        return std::nullopt;
    }
    std::string out;
    for (size_t i = 1; i + 1 < value.size(); ++i) {
        char c = value[i];
        if (c == '\\') {
            c = value[++i];
            if (c != '"' && c != '\\' && c != '/') {
                return std::nullopt;
            }
        } else if (static_cast<unsigned char>(c) < 0x20) {
            return std::nullopt;
        }
        out += c;
    }
    return out;
}

std::optional<uint64_t> numberValue(std::string_view value) {
    uint64_t number = 0;
    const auto [end, error] = std::from_chars(value.data(), value.data() + value.size(), number);
    if (error != std::errc() || end != value.data() + value.size()) {
        return std::nullopt;
    }
    return number;
}

/// The members of the object `value`.
std::optional<Members> members(std::string_view value) {
    size_t i = skipSpace(value, 0);
    if (i >= value.size() || value[i] != '{') {
        return std::nullopt;
    }
    Members out;
    i = skipSpace(value, i + 1);
    if (i < value.size() && value[i] == '}') {
        return out;
    }
    for (;;) {
        if (i >= value.size() || value[i] != '"') {
            return std::nullopt;
        }
        const size_t keyEnd = skipString(value, i);
        if (keyEnd == npos) {
            return std::nullopt;
        }
        std::string key = stringValue(value.substr(i, keyEnd - i)).value_or("");
        i = skipSpace(value, keyEnd);
        if (i >= value.size() || value[i] != ':') {
            return std::nullopt;
        }
        const size_t start = skipSpace(value, i + 1);
        const size_t end = skipValue(value, start, 1);
        if (end == npos) {
            return std::nullopt;
        }
        out.emplace_back(std::move(key), value.substr(start, end - start));
        i = skipSpace(value, end);
        if (i >= value.size()) {
            return std::nullopt;
        }
        if (value[i] == '}') {
            return out;
        }
        if (value[i] != ',') {
            return std::nullopt;
        }
        i = skipSpace(value, i + 1);
    }
}

/// The elements of the array `value`.
std::optional<std::vector<std::string_view>> elements(std::string_view value) {
    size_t i = skipSpace(value, 0);
    if (i >= value.size() || value[i] != '[') {
        return std::nullopt;
    }
    std::vector<std::string_view> out;
    i = skipSpace(value, i + 1);
    if (i < value.size() && value[i] == ']') {
        return out;
    }
    for (;;) {
        const size_t start = skipSpace(value, i);
        const size_t end = skipValue(value, start, 1);
        if (end == npos) {
            return std::nullopt;
        }
        out.push_back(value.substr(start, end - start));
        i = skipSpace(value, end);
        if (i >= value.size()) {
            return std::nullopt;
        }
        if (value[i] == ']') {
            return out;
        }
        if (value[i] != ',') {
            return std::nullopt;
        }
        ++i;
    }
}

std::optional<std::string_view> member(const Members &object, std::string_view key) {
    for (const auto &[name, value] : object) {
        if (name == key) {
            return value;
        }
    }
    return std::nullopt;
}

/// `sha256:<64 hex>` as lowercase hex.
std::optional<std::string> sha256FromDigest(std::string_view digest) {
    constexpr std::string_view prefix = "sha256:";
    if (digest.substr(0, prefix.size()) != prefix || digest.size() != prefix.size() + 64) {
        return std::nullopt;
    }
    std::string hex;
    for (char c : digest.substr(prefix.size())) {
        if (c >= 'A' && c <= 'F') {
            c = static_cast<char>(c - 'A' + 'a');
        }
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
            return std::nullopt;
        }
        hex += c;
    }
    return hex;
}

// ---- update.ini --------------------------------------------------------------

constexpr const char *kStateGroup = "Update";

std::string_view busyName(Busy busy) {
    switch (busy) {
    case Busy::Checking:
        return "checking";
    case Busy::Downloading:
        return "downloading";
    case Busy::Installing:
        return "installing";
    case Busy::None:
        break;
    }
    return {};
}

int64_t toInteger(const std::optional<std::string> &text) {
    int64_t number = 0;
    if (text) {
        std::from_chars(text->data(), text->data() + text->size(), number);
    }
    return number;
}

} // namespace

// MARK: - Version

std::optional<Version> Version::parse(std::string_view text) {
    while (!text.empty() && (text.front() == ' ' || text.front() == '\n' || text.front() == '\t')) {
        text.remove_prefix(1);
    }
    while (!text.empty() && (text.back() == ' ' || text.back() == '\n' || text.back() == '\t')) {
        text.remove_suffix(1);
    }
    if (!text.empty() && (text.front() == 'v' || text.front() == 'V')) {
        text.remove_prefix(1);
    }
    if (const auto cut = text.find_first_of("-+"); cut != npos) {
        text = text.substr(0, cut);
    }
    unsigned numbers[3] = {};
    size_t count = 0;
    for (;;) {
        const auto dot = text.find('.');
        const auto part = text.substr(0, dot);
        // ASCII digits only: from_chars takes no sign, but no `+` must slip
        // past the check above either.
        if (count == 3 || part.empty() || part.find_first_not_of("0123456789") != npos) {
            return std::nullopt;
        }
        const auto [end, error] = std::from_chars(part.data(), part.data() + part.size(), numbers[count]);
        if (error != std::errc() || end != part.data() + part.size()) {
            return std::nullopt;
        }
        ++count;
        if (dot == npos) {
            break;
        }
        text.remove_prefix(dot + 1);
    }
    if (count != 3) {
        return std::nullopt;
    }
    return Version{numbers[0], numbers[1], numbers[2]};
}

std::string Version::str() const {
    return std::to_string(major) + "." + std::to_string(minor) + "." + std::to_string(patch);
}

bool operator<(const Version &a, const Version &b) {
    if (a.major != b.major) {
        return a.major < b.major;
    }
    if (a.minor != b.minor) {
        return a.minor < b.minor;
    }
    return a.patch < b.patch;
}

bool operator==(const Version &a, const Version &b) {
    return a.major == b.major && a.minor == b.minor && a.patch == b.patch;
}

// MARK: - The feed

bool isReleaseTag(std::string_view tag) {
    // ASCII letters, digits and `.-+` alone: a suffix is ignored by
    // Version::parse, but the whole tag goes into file names.
    return !tag.empty() && tag.front() == 'v' && Version::parse(tag) &&
           tag.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-+") == npos;
}

std::optional<std::string> extractTag(std::string_view json) {
    const auto release = members(json);
    const auto value = release ? member(*release, "tag_name") : std::nullopt;
    auto tag = value ? stringValue(*value) : std::nullopt;
    if (!tag || !isReleaseTag(*tag)) {
        return std::nullopt;
    }
    return tag;
}

std::optional<Asset> extractAsset(std::string_view json, std::string_view name) {
    const auto release = members(json);
    const auto assets = release ? member(*release, "assets") : std::nullopt;
    const auto list = assets ? elements(*assets) : std::nullopt;
    if (!list) {
        return std::nullopt;
    }
    for (const auto element : *list) {
        const auto asset = members(element);
        if (!asset) {
            continue;
        }
        const auto assetName = member(*asset, "name");
        if (!assetName || stringValue(*assetName) != name) {
            continue;
        }
        const auto url = member(*asset, "browser_download_url");
        auto urlText = url ? stringValue(*url) : std::nullopt;
        if (!urlText || urlText->empty()) {
            return std::nullopt;
        }
        Asset found;
        found.name = std::string(name);
        found.url = std::move(*urlText);
        if (const auto size = member(*asset, "size")) {
            found.size = numberValue(*size).value_or(0);
        }
        if (const auto digest = member(*asset, "digest")) {
            if (const auto text = stringValue(*digest)) {
                found.sha256 = sha256FromDigest(*text);
            }
        }
        return found;
    }
    return std::nullopt;
}

std::string releasePage(std::string_view tag) {
    return "https://github.com/hronro/ime-jd/releases/tag/" + std::string(tag);
}

std::string_view hostArch() {
#if defined(__x86_64__)
    return "x86_64";
#elif defined(__aarch64__)
    return "arm64";
#else
    return "";
#endif
}

std::string tarballName(std::string_view tag, std::string_view arch) {
    return "jd-ime-" + std::string(tag) + "-linux-" + std::string(arch) + ".tar.xz";
}

// MARK: - State

State State::parse(const std::string &text) {
    const auto value = [&](const char *key) { return files::iniValue(text, kStateGroup, key); };
    State state;
    state.lastCheck = toInteger(value("LastCheck"));
    state.latest = value("Latest").value_or("");
    state.tarball.name = value("TarballName").value_or("");
    state.tarball.url = value("TarballUrl").value_or("");
    state.tarball.size = static_cast<uint64_t>(toInteger(value("TarballSize")));
    if (auto sha256 = value("TarballSha256"); sha256 && !sha256->empty()) {
        state.tarball.sha256 = std::move(sha256);
    }
    state.notified = value("Notified").value_or("");
    state.installed = value("Installed").value_or("");
    const auto busy = value("Busy").value_or("");
    for (Busy candidate : {Busy::Checking, Busy::Downloading, Busy::Installing}) {
        if (busy == busyName(candidate)) {
            state.busy = candidate;
        }
    }
    state.busyPid = static_cast<int>(toInteger(value("BusyPid")));
    return state;
}

std::string State::serialize() const {
    std::string text = std::string("[") + kStateGroup + "]\n";
    const auto line = [&](const char *key, const std::string &value) {
        if (!value.empty()) {
            text += std::string(key) + "=" + value + "\n";
        }
    };
    line("LastCheck", lastCheck ? std::to_string(lastCheck) : "");
    line("Latest", latest);
    line("TarballName", tarball.name);
    line("TarballUrl", tarball.url);
    line("TarballSize", tarball.size ? std::to_string(tarball.size) : "");
    line("TarballSha256", tarball.sha256.value_or(""));
    line("Notified", notified);
    line("Installed", installed);
    line("Busy", std::string(busyName(busy)));
    line("BusyPid", busy != Busy::None && busyPid ? std::to_string(busyPid) : "");
    return text;
}

std::optional<Version> newerRelease(const State &state, std::string_view current) {
    const auto latest = Version::parse(state.latest);
    const auto running = Version::parse(current);
    if (!latest || !running || !(*running < *latest)) {
        return std::nullopt;
    }
    return latest;
}

// MARK: - UpdateClient

UpdateClient::UpdateClient(std::string directory, std::string updater, std::string current, Spawn spawn)
    : directory_(std::move(directory)), updater_(std::move(updater)), current_(std::move(current)),
      spawn_(std::move(spawn)) {
    refresh();
}

void UpdateClient::refresh() {
    std::optional<std::string> text;
    files::readFile(directory_ + "/" + kUpdateStateName, text);
    state_ = State::parse(text.value_or(""));

    std::optional<std::string> settings;
    files::readFile(directory_ + "/" + kSettingsName, settings);
    const auto value = settings ? files::iniValue(*settings, kSettingsGroup, kAutoCheckKey) : std::nullopt;
    // GKeyFile's spellings of false; anything else leaves it on.
    autoCheck_ = !(value == "false" || value == "0");
}

Busy UpdateClient::busy() const {
    if (state_.busy == Busy::None || state_.busyPid <= 0) {
        return Busy::None;
    }
    // Still the updater's process: not gone — crashed, or ended with the
    // session — and not reused since by another program. The kernel keeps 15
    // bytes of a program's name.
    std::optional<std::string> comm;
    files::readFile("/proc/" + std::to_string(state_.busyPid) + "/comm", comm);
    const std::string program = updater_.substr(updater_.rfind('/') + 1).substr(0, 15);
    if (!comm || *comm != program + "\n") {
        return Busy::None;
    }
    return state_.busy;
}

std::optional<Version> UpdateClient::offered() const {
    const auto release = newerRelease(state_, current_);
    const auto installed = Version::parse(state_.installed);
    if (!release || (installed && !(*installed < *release))) {
        return std::nullopt;
    }
    return release;
}

std::optional<Version> UpdateClient::awaitingRestart() const {
    const auto installed = Version::parse(state_.installed);
    const auto running = Version::parse(current_);
    if (!installed || !running || !(*running < *installed)) {
        return std::nullopt;
    }
    return installed;
}

void UpdateClient::checkIfDue() {
    const auto current = Version::parse(current_);
    if (!autoCheck_ || !current || current->isPlaceholder() || busy() != Busy::None) {
        return;
    }
    const int64_t now = std::time(nullptr);
    // A clock set back leaves a stamp in the future: that is due too.
    const auto recent = [&](int64_t stamp) { return stamp != 0 && stamp <= now && now - stamp < kCheckInterval; };
    if (recent(state_.lastCheck) || recent(lastSpawn_)) {
        return;
    }
    lastSpawn_ = now;
    spawn_({updater_, "check"});
}

void UpdateClient::activate() {
    refresh();
    if (busy() != Busy::None) {
        return;
    }
    // Waiting for a restart, the updater finds nothing newer than what it
    // installed, and says how to restart.
    if (offered() || awaitingRestart()) {
        spawn_({updater_, "install"});
    } else {
        spawn_({updater_, "check", "--interactive"});
    }
}

std::string UpdateClient::label() const {
    switch (busy()) {
    case Busy::Checking:
        return "正在检查更新…";
    case Busy::Downloading:
        return "正在下载安装包…";
    case Busy::Installing:
        return "正在安装新版本…";
    case Busy::None:
        break;
    }
    if (offered()) {
        return "发现新版本 " + state_.latest + "，下载并安装…";
    }
    if (const auto installed = awaitingRestart()) {
        return "已更新到 v" + installed->str() + "，重启输入法后生效…";
    }
    return "检查更新…";
}

bool UpdateClient::sensitive() const { return busy() == Busy::None; }

bool UpdateClient::setAutoCheck(bool on) {
    const std::string path = directory_ + "/" + kSettingsName;
    std::optional<std::string> settings;
    if (files::readFile(path, settings) != 0) {
        return false;
    }
    files::makeDirectories(directory_);
    if (!files::writeFileAtomically(
            path, files::withIniValue(settings.value_or(""), kSettingsGroup, kAutoCheckKey, on ? "true" : "false"))) {
        return false;
    }
    autoCheck_ = on;
    return true;
}

} // namespace imejd::update
