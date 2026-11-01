// The user dictionary store, as the macOS client tests its own
// (macos/JdIMETests/UserDictStoreTests.swift), plus what is Linux's: the
// switch in settings.ini, and the inotify watch.
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <string>
#include <vector>

#include "check.h"
#include "temp_dir.h"
#include "user_dict.h"

using imejd::UserDictStore;
namespace file = imejd::userdict_file;

TEST(noFileMeansNoDictionary) {
    TempDir dir;
    UserDictStore store(dir.path());
    CHECK(!store.dictionary());
    CHECK(!store.activeDictionary());
    CHECK_EQ(store.generation(), 0u);
    CHECK_EQ(store.statusText(), "用户自造词：尚无词条");
    // Nothing reloaded, nothing changed.
    CHECK(!store.reload());
    CHECK_EQ(store.generation(), 0u);
}

TEST(theFileIsBuiltAtStartAndOnlyRebuiltWhenItChanges) {
    TempDir dir;
    dir.write(file::fileName, "键道\tzzzzzz\n不\tb\n");
    UserDictStore store(dir.path());
    CHECK(store.dictionary());
    CHECK_EQ(store.dictionary()->entries(), 1u);
    CHECK_EQ(store.report()->dropped, 1u);
    CHECK_EQ(store.generation(), 1u);
    CHECK_EQ(store.statusText(), "用户自造词：1 条，1 条重复已忽略");

    // The same content again: nothing to do.
    dir.write(file::fileName, "键道\tzzzzzz\n不\tb\n");
    CHECK(!store.reload());
    CHECK_EQ(store.generation(), 1u);

    dir.write(file::fileName, "键道\tzzzzzz\n键道输入法\tzzzzza\n");
    CHECK(store.reload());
    CHECK_EQ(store.dictionary()->entries(), 2u);
    CHECK_EQ(store.generation(), 2u);

    // The file is gone: so is the dictionary.
    std::remove(store.filePath().c_str());
    CHECK(store.reload());
    CHECK(!store.dictionary());
    CHECK_EQ(store.generation(), 3u);
}

TEST(aBadLineIsSkippedAndCounted) {
    TempDir dir;
    dir.write(file::fileName, "键道\tzzzzzz\nno tab\n");
    UserDictStore store(dir.path());
    CHECK_EQ(store.dictionary()->entries(), 1u);
    CHECK_EQ(store.report()->invalid, 1u);
    CHECK_EQ(store.statusText(), "用户自造词：1 条，1 条无效已跳过");
}

TEST(aByteOrderMarkIsDropped) {
    TempDir dir;
    dir.write(file::fileName, "\xEF\xBB\xBF键道\tzzzzzz\n");
    UserDictStore store(dir.path());
    CHECK_EQ(store.dictionary()->entries(), 1u);
    CHECK_EQ(store.report()->invalid, 0u);
}

TEST(aFileThatIsNotUtf8IsReportedOnce) {
    TempDir dir;
    dir.write(file::fileName, std::string("\xC4\xE3\x09\x61\x0A"));
    std::vector<std::string> notified;
    UserDictStore store(dir.path(), [&](const std::string &title, const std::string &body) {
        notified.push_back(title + "：" + body);
    });
    CHECK(!store.dictionary());
    CHECK(store.lastError());
    CHECK(store.lastError()->kind == UserDictStore::LoadError::Kind::NotUtf8);
    CHECK_EQ(store.statusText(), "用户自造词：文件不是 UTF-8 编码");
    CHECK_EQ(notified.size(), static_cast<size_t>(1));
    CHECK_EQ(notified.at(0), "用户自造词未能加载：文件不是 UTF-8 编码。当前没有加载用户自造词。");

    // The same bad content is not reported again.
    store.reload();
    CHECK_EQ(notified.size(), static_cast<size_t>(1));
}

TEST(aFailedRebuildKeepsTheLastGoodDictionary) {
    TempDir dir;
    dir.write(file::fileName, "键道\tzzzzzz\n");
    std::vector<std::string> notified;
    UserDictStore store(dir.path(), [&](const std::string &, const std::string &body) { notified.push_back(body); });
    const auto before = store.dictionary();

    dir.write(file::fileName, std::string("\xFF\n"));
    CHECK(!store.reload());
    CHECK(store.dictionary() == before);
    CHECK_EQ(notified.size(), static_cast<size_t>(1));
    CHECK_EQ(notified.at(0), "文件不是 UTF-8 编码。已沿用上一次成功加载的词库。");

    // Fixed: back to normal.
    dir.write(file::fileName, "键道\tzzzzzz\n键道输入法\tzzzzza\n");
    CHECK(store.reload());
    CHECK(!store.lastError());
    CHECK_EQ(store.dictionary()->entries(), 2u);
}

TEST(theSwitchChangesTheActiveDictionaryWithoutTouchingTheFile) {
    TempDir dir;
    dir.write(file::fileName, "键道\tzzzzzz\n");
    UserDictStore store(dir.path());
    // Off by default: the file is loaded, but engines get nothing.
    CHECK(!store.isEnabled());
    CHECK(store.dictionary());
    CHECK(!store.activeDictionary());
    CHECK_EQ(store.generation(), 1u);
    CHECK(store.setEnabled(false));
    CHECK_EQ(store.generation(), 1u);

    CHECK(store.setEnabled(true));
    CHECK(store.activeDictionary());
    CHECK_EQ(store.generation(), 2u);
    CHECK_EQ(dir.read("settings.ini"), "[UserDict]\nEnabled=true\n");
    CHECK_EQ(dir.read(file::fileName), "键道\tzzzzzz\n");

    CHECK(store.setEnabled(false));
    CHECK(!store.activeDictionary());
    CHECK(store.dictionary());
    CHECK_EQ(store.generation(), 3u);
    CHECK_EQ(dir.read("settings.ini"), "[UserDict]\nEnabled=false\n");
}

TEST(theSwitchIsSharedThroughSettingsIni) {
    TempDir dir;
    // Written by the editor, or by the other framework's frontend.
    dir.write("settings.ini", "# kept\n[Window]\nWidth=800\n\n[UserDict]\nEnabled=true\n");
    UserDictStore store(dir.path());
    CHECK(store.isEnabled());

    CHECK(store.setEnabled(false));
    CHECK_EQ(dir.read("settings.ini"), "# kept\n[Window]\nWidth=800\n\n[UserDict]\nEnabled=false\n");

    // Flipped elsewhere: a reload picks it up, and engines must follow.
    dir.write("settings.ini", "[UserDict]\nEnabled=true\n");
    const auto generation = store.generation();
    CHECK(store.reload());
    CHECK(store.isEnabled());
    CHECK_EQ(store.generation(), generation + 1);
}

TEST(theSwitchIsAddedToSettingsItDoesNotHaveYet) {
    TempDir dir;
    dir.write("settings.ini", "[Window]\nWidth=800\n");
    UserDictStore store(dir.path());
    CHECK(store.setEnabled(true));
    CHECK_EQ(dir.read("settings.ini"), "[Window]\nWidth=800\n\n[UserDict]\nEnabled=true\n");
}

TEST(theWatchSeesSavesToOurFilesOnly) {
    TempDir dir;
    UserDictStore store(dir.path());
    CHECK(store.watchFd() >= 0);
    CHECK(!store.drainWatch());

    dir.write("unrelated.txt", "x");
    CHECK(!store.drainWatch());

    dir.write(file::fileName, "键道\tzzzzzz\n");
    CHECK(store.drainWatch());
    CHECK(store.reload());

    store.setEnabled(true);
    CHECK(store.drainWatch());

    // The update check's record, which the menus show.
    dir.write("update.ini", "[Update]\n");
    CHECK(store.drainWatch());
}

TEST(ensureFileWritesTheHeaderOnce) {
    TempDir dir;
    UserDictStore store(dir.path());
    CHECK(store.ensureFile());
    CHECK_EQ(dir.read(file::fileName), file::header() + "\n");
    store.reload();
    CHECK_EQ(store.dictionary()->entries(), 0u);

    dir.write(file::fileName, "键道\tzzzzzz\n");
    CHECK(store.ensureFile());
    CHECK_EQ(dir.read(file::fileName), "键道\tzzzzzz\n");
}

namespace {

/// Sets an environment variable for as long as it lives.
class ScopedEnv {
public:
    ScopedEnv(const char *name, const char *value) : name_(name) {
        if (const char *old = std::getenv(name)) {
            old_ = old;
        }
        setenv(name, value, 1);
    }
    ~ScopedEnv() {
        if (old_) {
            setenv(name_, old_->c_str(), 1);
        } else {
            unsetenv(name_);
        }
    }

private:
    const char *name_;
    std::optional<std::string> old_;
};

} // namespace

TEST(theDefaultDirectoryFollowsXdgConfigHome) {
    {
        ScopedEnv config("XDG_CONFIG_HOME", "/somewhere/config");
        CHECK_EQ(UserDictStore::defaultDirectory(), "/somewhere/config/ime-jd");
    }
    // A relative path is not a valid XDG_CONFIG_HOME.
    ScopedEnv config("XDG_CONFIG_HOME", "relative");
    ScopedEnv home("HOME", "/home/someone");
    CHECK_EQ(UserDictStore::defaultDirectory(), "/home/someone/.config/ime-jd");
}

TEST(hashIsFnv1a) {
    CHECK_EQ(file::hash(""), 0xcbf29ce484222325ull);
    CHECK_EQ(file::hash("a"), 0xaf63dc4c8601ec8cull);
}

TEST(utf8Validation) {
    CHECK(file::isUtf8("键道\tzzzzzz\n"));
    CHECK(!file::isUtf8("\xC4\xE3"));
    CHECK(!file::isUtf8("\xC0\xAF"));          // overlong
    CHECK(!file::isUtf8("\xED\xA0\x80"));      // a surrogate
    CHECK(!file::isUtf8("\xF4\x90\x80\x80"));  // past U+10FFFF
    CHECK(file::isUtf8("\xF0\x9F\x98\x80"));   // 😀
}
