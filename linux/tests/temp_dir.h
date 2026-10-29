// A directory of a test's own, removed when the test is done.
#pragma once

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <string_view>

class TempDir {
public:
    TempDir() {
        const char *base = std::getenv("TMPDIR");
        std::string pattern = std::string(base && *base ? base : "/tmp") + "/imejd-test-XXXXXX";
        path_ = mkdtemp(pattern.data()) ? pattern : std::string();
    }
    ~TempDir() {
        if (!path_.empty()) {
            std::error_code ignored;
            std::filesystem::remove_all(path_, ignored);
        }
    }

    TempDir(const TempDir &) = delete;
    TempDir &operator=(const TempDir &) = delete;

    const std::string &path() const { return path_; }
    std::string file(std::string_view name) const { return path_ + "/" + std::string(name); }

    void write(std::string_view name, std::string_view content) const {
        std::ofstream(file(name), std::ios::binary | std::ios::trunc) << content;
    }

    std::string read(std::string_view name) const {
        std::ifstream in(file(name), std::ios::binary);
        return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
    }

private:
    std::string path_;
};
