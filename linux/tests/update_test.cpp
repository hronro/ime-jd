// The update check's shared rules, as Windows tests its own
// (windows/src/update/feed.rs): versions, the feed, update.ini, and the
// menu's side, UpdateClient. And the SHA-256 downloads are checked with.
#include <algorithm>
#include <ctime>
#include <fstream>
#include <optional>
#include <string>
#include <vector>

#include <unistd.h>

#include "check.h"
#include "sha256.h"
#include "temp_dir.h"
#include "update.h"

using namespace imejd::update;

namespace {

std::string show(const std::optional<Version> &version) { return version ? version->str() : "none"; }

std::string show(const std::optional<std::string> &text) { return text ? *text : "none"; }

} // namespace

// MARK: - Versions

TEST(versionsParseFromTagsAndPlainVersions) {
    CHECK_EQ(show(Version::parse("v0.6.0")), "0.6.0");
    CHECK_EQ(show(Version::parse("0.6.0")), "0.6.0");
    CHECK_EQ(show(Version::parse("V1.2.3")), "1.2.3");
    CHECK_EQ(show(Version::parse(" v0.10.1\n")), "0.10.1");
    CHECK_EQ(show(Version::parse("01.002.3")), "1.2.3");
    // Pre-release and build suffixes are ignored.
    CHECK_EQ(show(Version::parse("v1.0.0-rc1")), "1.0.0");
    CHECK_EQ(show(Version::parse("1.0.0+build.7")), "1.0.0");
    CHECK_EQ(show(Version::parse("v1.0.0-beta.2+exp")), "1.0.0");
}

TEST(malformedVersionsDoNotParse) {
    for (const char *bad : {"", "v", "1.2", "1.2.3.4", "a.b.c", "1.2.x", "1..3", "v1.2.-3", "+1.2.3", "١.٢.٣",
                            "1.2.3 4", "99999999999.0.0"}) {
        CHECK_EQ(show(Version::parse(bad)), "none");
    }
}

TEST(versionsOrderNumerically) {
    const auto v = [](const char *text) { return *Version::parse(text); };
    CHECK(v("0.9.9") < v("0.10.0"));
    CHECK(v("0.6.0") < v("1.0.0"));
    CHECK(v("0.6.0") < v("0.6.1"));
    CHECK(!(v("0.6.1") < v("0.6.1")));
    CHECK(v("0.6.0") == v("v0.6.0-rc1"));
    CHECK(v("0.0.0").isPlaceholder());
    CHECK(!v("0.0.1").isPlaceholder());
}

// MARK: - The feed

namespace {

// A trimmed but faithful `releases/latest`: nested objects with keys of
// their own, a string mentioning the field, and assets in GitHub's order —
// the tarball after a package whose name starts the same, the arm64 one
// without a digest.
constexpr const char *kFeed = R"({
  "url": "https://api.github.com/repos/hronro/ime-jd/releases/1",
  "html_url": "https://github.com/hronro/ime-jd/releases/tag/v0.9.2",
  "author": { "login": "hronro", "name": "jd-ime-v0.9.2-linux-x86_64.tar.xz", "tag_name": "v9.9.9" },
  "tag_name": "v0.9.2",
  "name": "v0.9.2",
  "draft": false,
  "assets": [
    {
      "url": "https://api.github.com/repos/hronro/ime-jd/releases/assets/1",
      "name": "jd-ime-v0.9.2-linux-x86_64-fcitx5.deb",
      "label": null,
      "uploader": { "login": "hronro", "url": "https://api.github.com/users/hronro" },
      "size": 4100000,
      "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
      "browser_download_url": "https://github.com/hronro/ime-jd/releases/download/v0.9.2/jd-ime-v0.9.2-linux-x86_64-fcitx5.deb"
    },
    {
      "url": "https://api.github.com/repos/hronro/ime-jd/releases/assets/2",
      "id": 2,
      "name": "jd-ime-v0.9.2-linux-x86_64.tar.xz",
      "uploader": { "login": "hronro", "id": 7, "name": "someone", "size": 1, "type": "User" },
      "content_type": "application/x-xz",
      "state": "uploaded",
      "size": 4980736,
      "download_count": 3,
      "digest": "sha256:AC0C7173E5F5D2177DE53FBF6AE0B7C781D43ECD5C515838C4D5679A5DD1DA87",
      "browser_download_url": "https://github.com/hronro/ime-jd/releases/download/v0.9.2/jd-ime-v0.9.2-linux-x86_64.tar.xz"
    },
    {
      "name": "jd-ime-v0.9.2-linux-arm64.tar.xz",
      "size": 4900000,
      "browser_download_url": "https://github.com/hronro/ime-jd/releases/download/v0.9.2/jd-ime-v0.9.2-linux-arm64.tar.xz"
    }
  ],
  "body": "notes mentioning \"tag_name\": \"v9.9.9\" should not matter"
})";

} // namespace

TEST(theTagIsReadFromTheFeed) {
    CHECK_EQ(show(extractTag(kFeed)), "v0.9.2");
    CHECK_EQ(show(extractTag(R"({"tag_name":"v1.2.3"})")), "v1.2.3");
    CHECK_EQ(show(extractTag("{ \"tag_name\" \t:\n \"v1.2.3-rc1\" }")), "v1.2.3-rc1");
    // The field, not the same words inside another string.
    CHECK_EQ(show(extractTag(R"({"body": "see \"tag_name\": x", "tag_name": "v2.0.0"})")), "v2.0.0");
    CHECK_EQ(releasePage("v1.2.3"), "https://github.com/hronro/ime-jd/releases/tag/v1.2.3");
}

TEST(aDocumentThatIsNotAVersionedReleaseHasNoTag) {
    const char *notReleases[] = {
        "not json",
        R"({"message": "API rate limit exceeded for 203.0.113.7.", "documentation_url": "https://docs.github.com"})",
        R"({"tag_name": "nightly"})",
        R"({"tag_name": 123})",
        R"({"tag_name": "1.0.0"})",
        R"({"tag_name": "v1.0.0\n"})",
        R"({"tag_name": "v1.0.0\u0020evil"})",
        R"({"tag_name": "v1.0.0/../x"})",
        R"({"tag_name": "v1.0.0")",
        R"(["tag_name", "v1.0.0"])",
        R"({"author": {"tag_name": "v1.0.0"}})",
    };
    for (const char *bad : notReleases) {
        CHECK_EQ(show(extractTag(bad)), "none");
    }
    // Nested deeper than any feed: read as nothing.
    std::string deep = R"({"a": )" + std::string(40, '[') + std::string(40, ']') + R"(, "tag_name": "v1.0.0"})";
    CHECK_EQ(show(extractTag(deep)), "none");
}

TEST(theTarballIsPickedByItsExactName) {
    CHECK_EQ(tarballName("v0.9.2", "x86_64"), "jd-ime-v0.9.2-linux-x86_64.tar.xz");
    CHECK_EQ(tarballName("v1.2.3", "arm64"), "jd-ime-v1.2.3-linux-arm64.tar.xz");
    CHECK(hostArch() == "x86_64" || hostArch() == "arm64");

    const auto tarball = extractAsset(kFeed, "jd-ime-v0.9.2-linux-x86_64.tar.xz");
    CHECK(tarball.has_value());
    if (tarball) {
        CHECK_EQ(tarball->name, "jd-ime-v0.9.2-linux-x86_64.tar.xz");
        CHECK_EQ(tarball->url,
                 "https://github.com/hronro/ime-jd/releases/download/v0.9.2/jd-ime-v0.9.2-linux-x86_64.tar.xz");
        CHECK_EQ(tarball->size, 4980736u);
        // Uppercase in the feed; kept lowercase.
        CHECK_EQ(show(tarball->sha256), "ac0c7173e5f5d2177de53fbf6ae0b7c781d43ecd5c515838c4d5679a5dd1da87");
    }

    // The arm64 one has no digest.
    const auto arm = extractAsset(kFeed, "jd-ime-v0.9.2-linux-arm64.tar.xz");
    CHECK(arm.has_value());
    if (arm) {
        CHECK_EQ(arm->size, 4900000u);
        CHECK_EQ(show(arm->sha256), "none");
    }

    CHECK(!extractAsset(kFeed, "jd-ime-v0.9.2-linux-riscv64.tar.xz"));
    CHECK(!extractAsset(R"({"tag_name":"v1.0.0"})", "x.tar.xz"));
    CHECK(!extractAsset(R"({"assets": [{"name": "x.tar.xz"}]})", "x.tar.xz"));
    CHECK(!extractAsset(R"({"assets": [{"name": "x.tar.xz", "browser_download_url": ""}]})", "x.tar.xz"));
    // A digest of another kind, or not one at all, is no digest.
    CHECK_EQ(show(extractAsset(R"({"assets": [{"name": "x", "browser_download_url": "https://h/x",
                                               "digest": "md5:0123456789abcdef0123456789abcdef"}]})",
                               "x")
                      ->sha256),
             "none");
}

TEST(releaseTagsAreSafeInFileNames) {
    CHECK(isReleaseTag("v0.9.2"));
    CHECK(isReleaseTag("v1.0.0-rc1"));
    CHECK(!isReleaseTag("0.9.2"));
    CHECK(!isReleaseTag("v0.9"));
    CHECK(!isReleaseTag("v0.9.2/.."));
    CHECK(!isReleaseTag("v0.9.2 x"));
    CHECK(!isReleaseTag(""));
}

// MARK: - update.ini

TEST(theStateRoundTripsThroughUpdateIni) {
    State state;
    state.lastCheck = 1700000000;
    state.latest = "v0.9.2";
    state.tarball.name = "jd-ime-v0.9.2-linux-x86_64.tar.xz";
    state.tarball.url = "https://github.com/hronro/ime-jd/releases/download/v0.9.2/jd-ime-v0.9.2-linux-x86_64.tar.xz";
    state.tarball.size = 4980736;
    state.tarball.sha256 = "ac0c7173e5f5d2177de53fbf6ae0b7c781d43ecd5c515838c4d5679a5dd1da87";
    state.notified = "v0.9.2";
    state.installed = "v0.9.1";
    state.busy = Busy::Downloading;
    state.busyPid = 1234;

    const std::string text = state.serialize();
    CHECK_EQ(text, "[Update]\n"
                   "LastCheck=1700000000\n"
                   "Latest=v0.9.2\n"
                   "TarballName=jd-ime-v0.9.2-linux-x86_64.tar.xz\n"
                   "TarballUrl=https://github.com/hronro/ime-jd/releases/download/v0.9.2/"
                   "jd-ime-v0.9.2-linux-x86_64.tar.xz\n"
                   "TarballSize=4980736\n"
                   "TarballSha256=ac0c7173e5f5d2177de53fbf6ae0b7c781d43ecd5c515838c4d5679a5dd1da87\n"
                   "Notified=v0.9.2\n"
                   "Installed=v0.9.1\n"
                   "Busy=downloading\n"
                   "BusyPid=1234\n");
    const State back = State::parse(text);
    CHECK_EQ(back.lastCheck, state.lastCheck);
    CHECK_EQ(back.latest, state.latest);
    CHECK_EQ(back.tarball.name, state.tarball.name);
    CHECK_EQ(back.tarball.url, state.tarball.url);
    CHECK_EQ(back.tarball.size, state.tarball.size);
    CHECK_EQ(show(back.tarball.sha256), *state.tarball.sha256);
    CHECK_EQ(back.notified, state.notified);
    CHECK_EQ(back.installed, state.installed);
    CHECK(back.busy == Busy::Downloading);
    CHECK_EQ(back.busyPid, 1234);

    // Not busy: no process to name.
    state.busy = Busy::None;
    CHECK(state.serialize().find("BusyPid") == std::string::npos);
}

TEST(anEmptyOrStrangeUpdateIniIsNothingRecorded) {
    for (const char *text : {"", "[Update]\nBusy=sleeping\nLastCheck=soon\n", "[Other]\nLatest=v9.9.9\n"}) {
        const State state = State::parse(text);
        CHECK_EQ(state.lastCheck, 0);
        CHECK(state.busy == Busy::None);
        CHECK_EQ(show(newerRelease(state, "0.9.1")), "none");
    }
}

TEST(onlyANewerReleaseIsOffered) {
    State state;
    state.latest = "v0.9.2";
    CHECK_EQ(show(newerRelease(state, "0.9.1")), "0.9.2");
    CHECK_EQ(show(newerRelease(state, "0.9.2")), "none");
    CHECK_EQ(show(newerRelease(state, "0.10.0")), "none");
    CHECK_EQ(show(newerRelease(state, "not a version")), "none");
}

// MARK: - UpdateClient

namespace {

constexpr const char *kCurrent = "0.9.1";

/// This process's name as /proc has it, for a busy record that is this
/// test's own.
std::string ownName() {
    std::ifstream comm("/proc/self/comm");
    std::string name;
    std::getline(comm, name);
    return name;
}

/// A client over `dir` that records what it starts.
struct Client {
    explicit Client(const TempDir &dir, const std::string &updater = "/usr/lib/ime-jd/ime-jd-update",
                    const char *current = kCurrent)
        : client(dir.path(), updater, current,
                 [this](const std::vector<std::string> &args) { started.push_back(args); }) {}

    std::vector<std::vector<std::string>> started;
    UpdateClient client;
};

std::string updateIni(const std::string &lines) { return "[Update]\n" + lines; }

std::string stamp(int64_t secondsFromNow) { return std::to_string(std::time(nullptr) + secondsFromNow); }

using Args = std::vector<std::string>;

} // namespace

TEST(aCheckIsStartedWhenDueAndOnlyThen) {
    {
        // Never checked: due, once.
        TempDir dir;
        Client c(dir);
        c.client.checkIfDue();
        c.client.checkIfDue();
        CHECK_EQ(c.started.size(), 1u);
        CHECK(c.started.at(0) == (Args{"/usr/lib/ime-jd/ime-jd-update", "check"}));
    }
    {
        TempDir dir;
        dir.write("update.ini", updateIni("LastCheck=" + stamp(-60) + "\n"));
        Client c(dir);
        c.client.checkIfDue();
        CHECK(c.started.empty());
    }
    // A day ago; and in the future, as after the clock was set back.
    for (const int64_t ago : {-kCheckInterval - 60, int64_t(3600)}) {
        TempDir dir;
        dir.write("update.ini", updateIni("LastCheck=" + stamp(ago) + "\n"));
        Client c(dir);
        c.client.checkIfDue();
        CHECK_EQ(c.started.size(), 1u);
    }
}

TEST(noCheckIsStartedWhileSwitchedOffOrForAPlaceholderBuild) {
    {
        TempDir dir;
        dir.write("settings.ini", "[Update]\nCheckAutomatically=false\n");
        Client c(dir);
        CHECK(!c.client.autoCheck());
        c.client.checkIfDue();
        CHECK(c.started.empty());
    }
    {
        TempDir dir;
        Client c(dir, "/usr/lib/ime-jd/ime-jd-update", "0.0.0");
        c.client.checkIfDue();
        CHECK(c.started.empty());
    }
}

TEST(theMenuItemChecksOrInstalls) {
    TempDir dir;
    Client c(dir);
    CHECK_EQ(c.client.label(), "检查更新…");
    CHECK(c.client.sensitive());
    c.client.activate();
    CHECK(c.started.back() == (Args{"/usr/lib/ime-jd/ime-jd-update", "check", "--interactive"}));

    // The menu reads the record again when chosen.
    dir.write("update.ini", updateIni("Latest=v0.9.2\n"));
    c.client.activate();
    CHECK(c.started.back() == (Args{"/usr/lib/ime-jd/ime-jd-update", "install"}));
    CHECK_EQ(c.client.label(), "发现新版本 v0.9.2，下载并安装…");

    dir.write("update.ini", updateIni("Latest=v0.9.1\n"));
    c.client.refresh();
    CHECK_EQ(c.client.label(), "检查更新…");
}

TEST(anInstalledUpdateWaitsForARestart) {
    TempDir dir;
    dir.write("update.ini", updateIni("Latest=v0.9.2\nInstalled=v0.9.2\n"));
    Client c(dir);
    CHECK_EQ(c.client.label(), "已更新到 v0.9.2，重启输入法后生效…");
    // The updater, already the new version, says how to restart.
    c.client.activate();
    CHECK(c.started.back() == (Args{"/usr/lib/ime-jd/ime-jd-update", "install"}));

    // A release newer still is offered.
    dir.write("update.ini", updateIni("Latest=v0.9.3\nInstalled=v0.9.2\n"));
    c.client.refresh();
    CHECK_EQ(c.client.label(), "发现新版本 v0.9.3，下载并安装…");

    // Restarted: this build is the one installed.
    Client restarted(dir, "/usr/lib/ime-jd/ime-jd-update", "0.9.3");
    CHECK_EQ(restarted.client.label(), "检查更新…");
}

TEST(aBusyUpdaterIsLeftAlone) {
    TempDir dir;
    const std::string pid = std::to_string(getpid());
    dir.write("update.ini", updateIni("Latest=v0.9.2\nBusy=downloading\nBusyPid=" + pid + "\n"));
    // This test stands in for the updater: the process is alive, and has the
    // updater's name.
    Client c(dir, "/somewhere/" + ownName());
    CHECK_EQ(c.client.label(), "正在下载安装包…");
    CHECK(!c.client.sensitive());
    c.client.activate();
    c.client.checkIfDue();
    CHECK(c.started.empty());

    dir.write("update.ini", updateIni("Busy=checking\nBusyPid=" + pid + "\n"));
    c.client.refresh();
    CHECK_EQ(c.client.label(), "正在检查更新…");
    dir.write("update.ini", updateIni("Busy=installing\nBusyPid=" + pid + "\n"));
    c.client.refresh();
    CHECK_EQ(c.client.label(), "正在安装新版本…");
}

TEST(aBusyRecordOfAProcessGoneIsNotBelieved) {
    TempDir dir;
    // Another program has the process ID now: the updater crashed long ago.
    dir.write("update.ini", updateIni("Busy=checking\nBusyPid=" + std::to_string(getpid()) + "\n"));
    Client reused(dir);
    CHECK_EQ(reused.client.label(), "检查更新…");
    CHECK(reused.client.sensitive());

    // No such process: past any pid_max.
    dir.write("update.ini", updateIni("Busy=checking\nBusyPid=1073741824\n"));
    Client gone(dir, "/somewhere/" + ownName());
    CHECK_EQ(gone.client.label(), "检查更新…");
    gone.client.activate();
    CHECK_EQ(gone.started.size(), 1u);
}

TEST(theSwitchIsSavedBesideTheOtherSettings) {
    TempDir dir;
    dir.write("settings.ini", "[UserDict]\nEnabled=true\n");
    Client c(dir);
    CHECK(c.client.autoCheck());
    CHECK(c.client.setAutoCheck(false));
    CHECK(!c.client.autoCheck());
    CHECK_EQ(dir.read("settings.ini"), "[UserDict]\nEnabled=true\n\n[Update]\nCheckAutomatically=false\n");

    Client again(dir);
    CHECK(!again.client.autoCheck());
    CHECK(again.client.setAutoCheck(true));
    CHECK_EQ(dir.read("settings.ini"), "[UserDict]\nEnabled=true\n\n[Update]\nCheckAutomatically=true\n");

    // GKeyFile's other spelling of false.
    dir.write("settings.ini", "[Update]\nCheckAutomatically=0\n");
    c.client.refresh();
    CHECK(!c.client.autoCheck());
}

// MARK: - SHA-256

TEST(sha256MatchesTheStandardsVectors) {
    const auto digest = [](std::string_view text) {
        imejd::Sha256 hash;
        hash.update(text);
        return hash.hexDigest();
    };
    CHECK_EQ(digest(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    CHECK_EQ(digest("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    CHECK_EQ(digest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
             "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
    // Each side of the padding's boundaries.
    CHECK_EQ(digest(std::string(55, 'a')), "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318");
    CHECK_EQ(digest(std::string(56, 'a')), "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a");
    CHECK_EQ(digest(std::string(63, 'a')), "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34");
    CHECK_EQ(digest(std::string(64, 'a')), "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb");
    CHECK_EQ(digest(std::string(65, 'a')), "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0");
    CHECK_EQ(digest(std::string(119, 'a')), "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb");
    CHECK_EQ(digest(std::string(120, 'a')), "2f3d335432c70b580af0e8e1b3674a7c020d683aa5f73aaaedfdc55af904c21c");
}

TEST(sha256TakesItsInputInPiecesOfAnySize) {
    // A million `a`s, as a download arrives: pieces that straddle blocks.
    imejd::Sha256 hash;
    const std::string piece(997, 'a');
    size_t left = 1000000;
    for (size_t size = 1; left > 0; size = size % 997 + 1) {
        const size_t take = std::min(size, left);
        hash.update(piece.data(), take);
        left -= take;
    }
    CHECK_EQ(hash.hexDigest(), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
}
