#include "files.h"

#include <cerrno>
#include <cstdlib>
#include <vector>

#include <fcntl.h>
#include <pwd.h>
#include <sys/stat.h>
#include <unistd.h>

namespace imejd::files {

namespace {

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

/// `$<variable>/ime-jd` when the variable holds an absolute path,
/// `~/<fallback>/ime-jd` otherwise.
std::string xdgDirectory(const char *variable, const char *fallback) {
    const char *base = std::getenv(variable);
    if (base && base[0] == '/') {
        return std::string(base) + "/ime-jd";
    }
    const char *home = std::getenv("HOME");
    if (!home || !*home) {
        const passwd *user = getpwuid(getuid());
        home = user ? user->pw_dir : "";
    }
    return std::string(home) + "/" + fallback + "/ime-jd";
}

} // namespace

std::string configDirectory() { return xdgDirectory("XDG_CONFIG_HOME", ".config"); }

std::string cacheDirectory() { return xdgDirectory("XDG_CACHE_HOME", ".cache"); }

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

void makeDirectories(const std::string &path) {
    for (size_t slash = path.find('/', 1); slash != std::string::npos; slash = path.find('/', slash + 1)) {
        mkdir(path.substr(0, slash).c_str(), 0700);
    }
    mkdir(path.c_str(), 0700);
}

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

} // namespace imejd::files
