#include "user_dict.h"

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <new>
#include <vector>

#include <fcntl.h>
#include <pwd.h>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <unistd.h>

namespace imejd {

namespace {

constexpr const char *kSettingsName = "settings.ini";
constexpr const char *kGroup = "UserDict";
constexpr const char *kEnabledKey = "Enabled";
constexpr std::align_val_t kBlobAlignment{16};

std::string_view trim(std::string_view text) {
    const auto first = text.find_first_not_of(" \t\r");
    if (first == std::string_view::npos) {
        return {};
    }
    const auto last = text.find_last_not_of(" \t\r");
    return text.substr(first, last - first + 1);
}

std::vector<std::string> splitLines(const std::string &text) {
    std::vector<std::string> lines;
    size_t start = 0;
    while (start < text.size()) {
        const auto end = text.find('\n', start);
        if (end == std::string::npos) {
            lines.push_back(text.substr(start));
            break;
        }
        lines.push_back(text.substr(start, end - start));
        start = end + 1;
    }
    return lines;
}

bool isGroupLine(std::string_view line) {
    return !line.empty() && line.front() == '[';
}

/// The key a `key=value` line sets, or nothing for any other line.
std::optional<std::string_view> keyOf(std::string_view line) {
    if (line.empty() || line.front() == '#' || line.front() == ';') {
        return std::nullopt;
    }
    const auto eq = line.find('=');
    if (eq == std::string_view::npos) {
        return std::nullopt;
    }
    return trim(line.substr(0, eq));
}

/// The value of `key` in `[group]`, in the INI format GLib's GKeyFile reads.
std::optional<std::string> iniValue(const std::string &content, std::string_view group,
                                    std::string_view key) {
    bool inGroup = false;
    for (const auto &raw : splitLines(content)) {
        const auto line = trim(raw);
        if (isGroupLine(line)) {
            inGroup = line.substr(1, line.size() - 2) == group && line.back() == ']';
        } else if (inGroup && keyOf(line) == key) {
            return std::string(trim(line.substr(line.find('=') + 1)));
        }
    }
    return std::nullopt;
}

/// `content` with `key` in `[group]` set to `value`, every other line as it
/// was — the editor may keep settings of its own in the same file.
std::string withIniValue(const std::string &content, std::string_view group, std::string_view key,
                         std::string_view value) {
    auto lines = splitLines(content);
    const std::string setting = std::string(key) + "=" + std::string(value);
    const std::string header = "[" + std::string(group) + "]";

    size_t groupLine = lines.size();
    for (size_t i = 0; i < lines.size(); ++i) {
        if (trim(lines[i]) == header) {
            groupLine = i;
            break;
        }
    }
    if (groupLine == lines.size()) {
        if (!lines.empty() && !trim(lines.back()).empty()) {
            lines.emplace_back();
        }
        lines.push_back(header);
        lines.push_back(setting);
    } else {
        size_t i = groupLine + 1;
        for (; i < lines.size() && !isGroupLine(trim(lines[i])); ++i) {
            if (keyOf(trim(lines[i])) == key) {
                lines[i] = setting;
                break;
            }
        }
        if (i == lines.size() || isGroupLine(trim(lines[i]))) {
            lines.insert(lines.begin() + static_cast<std::ptrdiff_t>(groupLine) + 1, setting);
        }
    }

    std::string result;
    for (const auto &line : lines) {
        result += line;
        result += '\n';
    }
    return result;
}

/// Creates `path` and its parents. XDG asks for 0700 on directories created
/// on the user's behalf.
void makeDirectories(const std::string &path) {
    for (size_t slash = path.find('/', 1); slash != std::string::npos; slash = path.find('/', slash + 1)) {
        mkdir(path.substr(0, slash).c_str(), 0700);
    }
    mkdir(path.c_str(), 0700);
}

/// The file's bytes, or nothing when there is no file. Returns 0, or the
/// errno that kept it from being read.
int readFile(const std::string &path, std::optional<std::string> &out) {
    out.reset();
    const int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return errno == ENOENT ? 0 : errno;
    }
    std::string data;
    char buffer[64 * 1024];
    for (;;) {
        const ssize_t n = read(fd, buffer, sizeof buffer);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            const int error = errno;
            close(fd);
            return error;
        }
        if (n == 0) {
            break;
        }
        data.append(buffer, static_cast<size_t>(n));
    }
    close(fd);
    out = std::move(data);
    return 0;
}

bool writeAll(int fd, std::string_view content) {
    while (!content.empty()) {
        const ssize_t n = write(fd, content.data(), content.size());
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return false;
        }
        content.remove_prefix(static_cast<size_t>(n));
    }
    return true;
}

/// Replaces `path` with `content` in one rename, so a reader never sees half
/// a file.
bool writeFileAtomically(const std::string &path, std::string_view content) {
    const std::string temporary = path + ".tmp-" + std::to_string(getpid());
    const int fd = open(temporary.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) {
        return false;
    }
    const bool written = writeAll(fd, content) && fsync(fd) == 0;
    close(fd);
    if (!written || rename(temporary.c_str(), path.c_str()) != 0) {
        unlink(temporary.c_str());
        return false;
    }
    return true;
}

} // namespace

// MARK: - UserDictBlob

std::shared_ptr<const UserDictBlob> UserDictBlob::build(std::string_view text, uint64_t sourceTag,
                                                        jd_user_dict_report &report) {
    report = {};
    const size_t bound = jd_user_dict_blob_bound(text.data(), text.size());
    // 16-byte aligned; the engine requires 4.
    void *storage = ::operator new(bound, kBlobAlignment);
    size_t blobLength = 0;
    if (jd_user_dict_build(text.data(), text.size(), sourceTag, storage, bound, &blobLength, &report) !=
        JD_USER_DICT_OK) {
        ::operator delete(storage, kBlobAlignment);
        return nullptr;
    }
    return std::shared_ptr<const UserDictBlob>(new UserDictBlob(storage, blobLength, report.entries));
}

UserDictBlob::UserDictBlob(void *storage, size_t size, unsigned entries)
    : storage_(storage), size_(size), entries_(entries) {}

UserDictBlob::~UserDictBlob() { ::operator delete(storage_, kBlobAlignment); }

// MARK: - The file format

namespace userdict_file {

std::string header() {
    // 6: the longest code libjd accepts in a user dictionary.
    return "# 键道用户自造词：每行一条，格式为「词<TAB>编码」，编码由 a-z 组成，1 到 6 个字符。";
}

uint64_t hash(std::string_view text) {
    uint64_t hash = 0xcbf29ce484222325ull;
    for (const char c : text) {
        hash ^= static_cast<unsigned char>(c);
        hash *= 0x100000001b3ull;
    }
    return hash;
}

bool isUtf8(std::string_view text) {
    const auto *bytes = reinterpret_cast<const unsigned char *>(text.data());
    const size_t size = text.size();
    size_t i = 0;
    while (i < size) {
        const unsigned lead = bytes[i];
        if (lead < 0x80) {
            ++i;
            continue;
        }
        size_t length;
        uint32_t scalar;
        if (lead >= 0xc2 && lead <= 0xdf) {
            length = 2;
            scalar = lead & 0x1f;
        } else if (lead >= 0xe0 && lead <= 0xef) {
            length = 3;
            scalar = lead & 0x0f;
        } else if (lead >= 0xf0 && lead <= 0xf4) {
            length = 4;
            scalar = lead & 0x07;
        } else {
            return false;
        }
        if (size - i < length) {
            return false;
        }
        for (size_t k = 1; k < length; ++k) {
            const unsigned continuation = bytes[i + k];
            if ((continuation & 0xc0) != 0x80) {
                return false;
            }
            scalar = (scalar << 6) | (continuation & 0x3f);
        }
        // Overlong forms, surrogates, and anything past U+10FFFF.
        if ((length == 3 && (scalar < 0x800 || (scalar >= 0xd800 && scalar <= 0xdfff))) ||
            (length == 4 && (scalar < 0x10000 || scalar > 0x10ffff))) {
            return false;
        }
        i += length;
    }
    return true;
}

} // namespace userdict_file

// MARK: - UserDictStore

std::string UserDictStore::LoadError::message() const {
    switch (kind) {
    case Kind::NotUtf8:
        return "文件不是 UTF-8 编码";
    case Kind::Unreadable:
        return "无法读取文件：" + reason;
    case Kind::Build:
        switch (status) {
        case JD_USER_DICT_TOO_MANY_ENTRIES:
            return "第 " + std::to_string(line) + " 行起超过 " + std::to_string(JD_USER_DICT_MAX_ENTRIES) +
                   " 条上限";
        case JD_USER_DICT_TEXT_TOO_LONG:
            return "文件超过 8 MB 上限";
        default:
            return "无法编译词库（状态 " + std::to_string(status) + "）";
        }
    }
    return {};
}

UserDictStore::UserDictStore(std::string directory, FailureHandler onFailure)
    : directory_(std::move(directory)),
      filePath_(directory_ + "/" + userdict_file::fileName),
      settingsPath_(directory_ + "/" + kSettingsName),
      onFailure_(std::move(onFailure)) {
    // Make sure there is a directory to watch, and a place to write.
    makeDirectories(directory_);
    addWatch();
    enabled_ = readSwitch();
    reload();
}

UserDictStore::~UserDictStore() {
    if (watchFd_ >= 0) {
        close(watchFd_);
    }
}

std::string UserDictStore::defaultDirectory() {
    // XDG_CONFIG_HOME, when it is set to an absolute path; ~/.config
    // otherwise.
    const char *config = std::getenv("XDG_CONFIG_HOME");
    std::string base;
    if (config && config[0] == '/') {
        base = config;
    } else {
        const char *home = std::getenv("HOME");
        if (!home || !*home) {
            const passwd *user = getpwuid(getuid());
            home = user ? user->pw_dir : "";
        }
        base = std::string(home) + "/.config";
    }
    return base + "/ime-jd";
}

bool UserDictStore::setEnabled(bool enabled) {
    if (enabled == enabled_) {
        return true;
    }
    std::optional<std::string> settings;
    if (readFile(settingsPath_, settings) != 0) {
        return false;
    }
    makeDirectories(directory_);
    if (!writeFileAtomically(settingsPath_,
                             withIniValue(settings.value_or(""), kGroup, kEnabledKey, enabled ? "true" : "false"))) {
        return false;
    }
    enabled_ = enabled;
    ++generation_;
    return true;
}

std::shared_ptr<const UserDictBlob> UserDictStore::activeDictionary() const {
    return enabled_ ? dictionary_ : nullptr;
}

std::string UserDictStore::statusText() const {
    if (lastError_) {
        return "用户自造词：" + lastError_->message();
    }
    if (!dictionary_) {
        return "用户自造词：尚无词条";
    }
    std::string text = "用户自造词：" + std::to_string(dictionary_->entries()) + " 条";
    if (report_ && report_->invalid > 0) {
        text += "，" + std::to_string(report_->invalid) + " 条无效已跳过";
    }
    if (report_ && report_->dropped > 0) {
        text += "，" + std::to_string(report_->dropped) + " 条重复已忽略";
    }
    return text;
}

bool UserDictStore::reload() {
    bool changed = false;
    // The switch may have been flipped by another process: the other
    // framework's frontend, or the editor.
    const bool enabled = readSwitch();
    if (enabled != enabled_) {
        enabled_ = enabled;
        changed = true;
    }
    if (loadFile()) {
        changed = true;
    }
    if (changed) {
        ++generation_;
    }
    return changed;
}

bool UserDictStore::readSwitch() const {
    std::optional<std::string> settings;
    if (readFile(settingsPath_, settings) != 0 || !settings) {
        return false;
    }
    const auto value = iniValue(*settings, kGroup, kEnabledKey);
    // GKeyFile's spellings of true.
    return value == "true" || value == "1";
}

bool UserDictStore::loadFile() {
    std::optional<std::string> text;
    if (const int error = readFile(filePath_, text)) {
        LoadError failure;
        failure.kind = LoadError::Kind::Unreadable;
        failure.reason = std::strerror(error);
        return fail(std::move(failure), std::nullopt);
    }

    // Empty: no file.
    std::optional<uint64_t> hash;
    if (text) {
        // A UTF-8 BOM is dropped: libjd would otherwise take U+FEFF as part
        // of the first value.
        if (text->compare(0, 3, "\xEF\xBB\xBF") == 0) {
            text->erase(0, 3);
        }
        hash = userdict_file::hash(*text);
    }
    if (hash == builtHash_ && !lastError_) {
        return false;
    }
    if (failedHash_ && hash == failedHash_) {
        return false;
    }

    if (!text) {
        // The file is gone: so is the dictionary.
        dictionary_.reset();
        report_.reset();
        lastError_.reset();
        builtHash_.reset();
        failedHash_.reset();
        return true;
    }

    if (!userdict_file::isUtf8(*text)) {
        LoadError failure;
        failure.kind = LoadError::Kind::NotUtf8;
        return fail(std::move(failure), hash);
    }

    jd_user_dict_report report{};
    auto dictionary = UserDictBlob::build(*text, *hash, report);
    if (!dictionary) {
        LoadError failure;
        failure.kind = LoadError::Kind::Build;
        failure.status = report.status;
        failure.line = report.line;
        return fail(std::move(failure), hash);
    }
    dictionary_ = std::move(dictionary);
    report_ = report;
    lastError_.reset();
    builtHash_ = hash;
    failedHash_.reset();
    return true;
}

bool UserDictStore::fail(LoadError error, std::optional<uint64_t> hash) {
    lastError_ = std::move(error);
    failedHash_ = hash;
    // A failed rebuild after a text-editor save would otherwise go unseen
    // until the user wonders why a phrase does not come up.
    if (onFailure_) {
        const char *fallback = dictionary_ ? "已沿用上一次成功加载的词库。" : "当前没有加载用户自造词。";
        onFailure_("用户自造词未能加载", lastError_->message() + "。" + fallback);
    }
    return false;
}

bool UserDictStore::ensureFile() {
    makeDirectories(directory_);
    const int fd = open(filePath_.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    if (fd < 0) {
        return errno == EEXIST;
    }
    const bool written = writeAll(fd, userdict_file::header() + "\n");
    close(fd);
    return written;
}

void UserDictStore::addWatch() {
    if (watchFd_ < 0) {
        watchFd_ = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
        if (watchFd_ < 0) {
            return;
        }
    }
    // A save is a write closed in place, or — an editor's atomic save, or
    // ours — a rename into the directory.
    watchDescriptor_ = inotify_add_watch(watchFd_, directory_.c_str(),
                                         IN_CLOSE_WRITE | IN_MOVED_TO | IN_MOVED_FROM | IN_DELETE |
                                             IN_DELETE_SELF | IN_MOVE_SELF);
}

bool UserDictStore::drainWatch() {
    if (watchFd_ < 0) {
        return false;
    }
    bool relevant = false;
    bool lost = false;
    alignas(inotify_event) char buffer[4096];
    for (;;) {
        const ssize_t n = read(watchFd_, buffer, sizeof buffer);
        if (n <= 0) {
            break;
        }
        for (const char *p = buffer; p < buffer + n;) {
            const auto *event = reinterpret_cast<const inotify_event *>(p);
            if (event->mask & (IN_IGNORED | IN_DELETE_SELF | IN_MOVE_SELF)) {
                lost = true;
            } else if (event->len > 0) {
                const std::string_view name(event->name);
                if (name == userdict_file::fileName || name == kSettingsName) {
                    relevant = true;
                }
            }
            p += sizeof(inotify_event) + event->len;
        }
    }
    if (lost) {
        // The directory went away or was replaced: watch whatever is there
        // now, and look at it afresh.
        if (watchDescriptor_ >= 0) {
            inotify_rm_watch(watchFd_, watchDescriptor_);
        }
        makeDirectories(directory_);
        addWatch();
        relevant = true;
    }
    return relevant;
}

} // namespace imejd
