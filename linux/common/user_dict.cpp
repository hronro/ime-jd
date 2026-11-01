#include "user_dict.h"

#include <cerrno>
#include <cstring>
#include <new>

#include <fcntl.h>
#include <sys/inotify.h>
#include <unistd.h>

#include "files.h"

namespace imejd {

using files::iniValue;
using files::makeDirectories;
using files::readFile;
using files::withIniValue;
using files::writeAll;
using files::writeFileAtomically;

namespace {

constexpr const char *kGroup = "UserDict";
constexpr const char *kEnabledKey = "Enabled";
constexpr std::align_val_t kBlobAlignment{16};

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

std::string UserDictStore::defaultDirectory() { return files::configDirectory(); }

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
                if (name == userdict_file::fileName || name == kSettingsName || name == kUpdateStateName) {
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
