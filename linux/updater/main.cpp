// ime-jd-update: the generic tarball's update check and installer
// (common/update.h). The frontends' menus start it, and it runs on its own,
// one at a time:
//
//   ime-jd-update check [--interactive]
//       Reads the release feed and records what it found in update.ini. A
//       newer release is told about once; with --interactive — the menu
//       asked — every outcome is told, every time.
//   ime-jd-update install
//       Downloads the tarball update.ini names, checks it against the feed's
//       SHA-256, and runs its install.sh as root through pkexec, which asks
//       for the password the way the desktop does. Where that cannot be done
//       — no tarball for this machine, or 键道 not installed from one — it
//       opens the release page instead.
//
// What it has to say goes to the desktop's notification service. For tests,
// IMEJD_UPDATE_FEED names a feed on this machine (http://127.0.0.1 or
// localhost) to read instead of GitHub's; only then does IMEJD_UPDATE_SUDO
// name a program to run install.sh with in place of pkexec (empty: none),
// and an install go ahead over 键道 installed some other way.
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <optional>
#include <string>
#include <vector>

#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

#include <gio/gio.h>

#include "files.h"
#include "http.h"
#include "project.h"
#include "sha256.h"
#include "update.h"

namespace {

using namespace imejd;
using namespace imejd::update;

/// What install.sh keeps of what it installed, and nothing else leaves: the
/// mark of an install from the tarball.
constexpr const char *kTarballList = "/usr/lib/ime-jd/files.txt";
/// The Fcitx 5 addon's icon, which the tarball puts in the icon theme.
constexpr const char *kIcon = "fcitx-ime-jd";
constexpr const char *kRestartHint =
    "重启输入法框架（Fcitx 5：fcitx5 -r；IBus：ibus restart），或注销后重新登录即可生效。";
/// The feed is tens of kilobytes; an asset of no stated size, a release's
/// largest some megabytes.
constexpr size_t kFeedLimit = 4 << 20;
constexpr uint64_t kDownloadLimit = 256 << 20;

/// Where the feed is read from, and how install.sh is run: GitHub's and
/// pkexec, or a test's.
struct Setup {
    std::string feed = kFeedUrl;
    bool testing = false;
    std::string sudo = "pkexec";
};

bool isLoopbackHttp(std::string_view url) {
    for (const std::string_view host : {"http://127.0.0.1", "http://localhost"}) {
        if (url.substr(0, host.size()) == host &&
            (url.size() == host.size() || url[host.size()] == ':' || url[host.size()] == '/')) {
            return true;
        }
    }
    return false;
}

Setup setup() {
    Setup setup;
    const char *feed = std::getenv("IMEJD_UPDATE_FEED");
    if (feed && isLoopbackHttp(feed)) {
        setup.feed = feed;
        setup.testing = true;
        if (const char *sudo = std::getenv("IMEJD_UPDATE_SUDO")) {
            setup.sudo = sudo;
        }
    } else if (feed) {
        std::fprintf(stderr, "键道: IMEJD_UPDATE_FEED is not a feed on this machine; ignored\n");
    }
    return setup;
}

std::string runningTag() { return std::string("v") + kVersion; }

std::string userAgent() { return std::string("ime-jd-linux/") + kVersion; }

// ---- The record, the lock, and the user ----

State loadState() {
    std::optional<std::string> text;
    files::readFile(files::configDirectory() + "/" + kUpdateStateName, text);
    return State::parse(text.value_or(""));
}

void saveState(const State &state) {
    const std::string directory = files::configDirectory();
    files::makeDirectories(directory);
    if (!files::writeFileAtomically(directory + "/" + kUpdateStateName, state.serialize())) {
        std::fprintf(stderr, "键道: cannot write %s/%s: %s\n", directory.c_str(), kUpdateStateName,
                     std::strerror(errno));
    }
}

/// Marks the record busy with `busy`, as this process.
void setBusy(State &state, Busy busy) {
    state.busy = busy;
    state.busyPid = busy == Busy::None ? 0 : static_cast<int>(getpid());
    saveState(state);
}

/// One updater at a time: the lock is held until the process exits.
bool lockUpdater() {
    const std::string directory = files::cacheDirectory();
    files::makeDirectories(directory);
    const int fd = open((directory + "/update.lock").c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    return fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0;
}

/// Tells the user, through the desktop's notification service; and the log.
void notify(const std::string &title, const std::string &body) {
    std::printf("%s\n%s\n", title.c_str(), body.c_str());
    GError *error = nullptr;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
    if (!bus) {
        std::fprintf(stderr, "键道: no session bus to notify on: %s\n", error->message);
        g_error_free(error);
        return;
    }
    GVariantBuilder actions;
    g_variant_builder_init(&actions, G_VARIANT_TYPE("as"));
    GVariantBuilder hints;
    g_variant_builder_init(&hints, G_VARIANT_TYPE("a{sv}"));
    // Waited for: the process exits next.
    GVariant *reply = g_dbus_connection_call_sync(
        bus, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications",
        "Notify",
        g_variant_new("(susssasa{sv}i)", "键道", 0u, kIcon, title.c_str(), body.c_str(), &actions, &hints, -1),
        G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 10000, nullptr, &error);
    if (reply) {
        g_variant_unref(reply);
    } else {
        std::fprintf(stderr, "键道: cannot notify: %s\n", error->message);
        g_error_free(error);
    }
    g_object_unref(bus);
}

/// Opens `uri` the way the desktop opens it; false when nothing would.
bool openExternally(const std::string &uri) {
    std::printf("Opening %s\n", uri.c_str());
    GError *error = nullptr;
    const bool opened = g_app_info_launch_default_for_uri(uri.c_str(), nullptr, &error);
    if (!opened) {
        std::fprintf(stderr, "键道: cannot open %s: %s\n", uri.c_str(), error->message);
        g_error_free(error);
    }
    // A browser started over D-Bus is asked without waiting for its answer:
    // the request has to leave before this process does.
    if (GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr)) {
        g_dbus_connection_flush_sync(bus, nullptr, nullptr);
        g_object_unref(bus);
    }
    return opened;
}

// ---- Checking ----

struct Release {
    std::string tag;
    std::optional<Asset> tarball;
};

/// The latest release; nothing, and why in `reason`, when the feed could not
/// be read.
std::optional<Release> readFeed(const Setup &setup, std::string &reason) {
    http::Request request;
    request.url = setup.feed;
    request.userAgent = userAgent();
    request.headers = {"Accept: application/vnd.github+json", "X-GitHub-Api-Version: 2022-11-28"};
    request.allowHttp = setup.testing;
    std::string body;
    bool tooLarge = false;
    const auto response = http::get(request, [&](std::string_view piece) {
        tooLarge = body.size() + piece.size() > kFeedLimit;
        if (!tooLarge) {
            body += piece;
        }
        return !tooLarge;
    });
    if (tooLarge) {
        reason = "服务器返回的版本信息过大";
    } else if (!response.error.empty()) {
        reason = response.error;
    } else if (response.status != 200) {
        reason = "HTTP " + std::to_string(response.status);
    } else if (auto tag = extractTag(body)) {
        Release release;
        release.tarball = extractAsset(body, tarballName(*tag, hostArch()));
        release.tag = std::move(*tag);
        return release;
    } else {
        reason = "服务器没有返回可用的版本信息";
    }
    return std::nullopt;
}

/// Whether the release found can be installed here: the tarball for this
/// machine, with a digest to check it by, over 键道 installed from one.
bool installable(const Setup &setup, const State &state) {
    const Asset &tarball = state.tarball;
    const bool fromTarball = setup.testing || access(kTarballList, F_OK) == 0;
    const bool secure = tarball.url.compare(0, 8, "https://") == 0 || (setup.testing && isLoopbackHttp(tarball.url));
    return isReleaseTag(state.latest) && !hostArch().empty() && tarball.name == tarballName(state.latest, hostArch()) &&
           secure && tarball.sha256 && fromTarball;
}

int check(const Setup &setup, bool interactive) {
    if (!lockUpdater()) {
        return 0;
    }
    State state = loadState();
    state.installed = runningTag();
    // Stamped before the request, as on macOS, so a failing feed is tried
    // again tomorrow, not at every activation.
    state.lastCheck = std::time(nullptr);
    setBusy(state, Busy::Checking);

    std::string reason;
    const auto release = readFeed(setup, reason);
    if (!release) {
        setBusy(state, Busy::None);
        std::fprintf(stderr, "键道: update check failed: %s\n", reason.c_str());
        if (interactive) {
            notify("无法检查更新", reason + "\n可以稍后再试，或手动前往发布页面查看。");
        }
        return 1;
    }
    state.latest = release->tag;
    state.tarball = release->tarball.value_or(Asset{});
    const bool newer = newerRelease(state, kVersion).has_value();
    // One notification per new version; the menu keeps offering it.
    const bool tell = interactive || (newer && state.notified != state.latest);
    if (newer && tell) {
        state.notified = state.latest;
    }
    // Recorded first, so the menu offers the release as the notification
    // appears.
    setBusy(state, Busy::None);

    if (!tell) {
        return 0;
    }
    const std::string current = std::string("当前版本 ") + kVersion + "。";
    if (!newer) {
        notify("已是最新版本", std::string("键道输入法 ") + kVersion + " 已经是最新版本。");
    } else if (!interactive) {
        notify("键道输入法有新版本",
               state.latest + (installable(setup, state) ? " 已发布，可从输入法菜单下载并安装。"
                                                         : " 已发布，可从输入法菜单打开发布页面下载。"));
    } else if (installable(setup, state)) {
        notify("发现新版本 " + state.latest, current + "在输入法菜单中选择「发现新版本 " + state.latest +
                                                 "，下载并安装…」即可更新，安装时需要输入管理员密码。");
    } else {
        notify("发现新版本 " + state.latest, current + "此版本没有适用于本机的安装包，请前往发布页面下载。");
    }
    return 0;
}

// ---- Installing ----

/// Downloads `asset` to `path`, checked against its size and SHA-256.
/// Returns why it failed; nothing when it did not.
std::string download(const Setup &setup, const Asset &asset, const std::string &path) {
    const int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) {
        return "无法创建 " + path + "：" + std::strerror(errno);
    }
    http::Request request;
    request.url = asset.url;
    request.userAgent = userAgent();
    request.download = true;
    request.allowHttp = setup.testing;
    Sha256 hash;
    uint64_t received = 0;
    const uint64_t limit = asset.size ? asset.size : kDownloadLimit;
    bool tooLarge = false;
    bool unwritten = false;
    const auto response = http::get(request, [&](std::string_view piece) {
        if (received + piece.size() > limit) {
            tooLarge = true;
        } else if (!files::writeAll(fd, piece)) {
            unwritten = true;
        } else {
            hash.update(piece);
            received += piece.size();
            return true;
        }
        return false;
    });
    unwritten = close(fd) != 0 || unwritten;

    if (unwritten) {
        return "无法写入 " + path;
    }
    if (tooLarge) {
        return "下载的文件比预期的大，已放弃安装";
    }
    if (!response.error.empty()) {
        return response.error;
    }
    if (response.status != 200) {
        return "HTTP " + std::to_string(response.status);
    }
    if (asset.size && received != asset.size) {
        return "下载的文件不完整";
    }
    if (hash.hexDigest() != asset.sha256) {
        return "下载的文件校验失败（SHA-256 不匹配），已放弃安装";
    }
    return {};
}

/// Runs `argv` and waits for it, its output to `log` when one is named.
/// Returns its exit status — 1 when a signal ended it — or -1 when it could
/// not be started.
int run(const std::vector<std::string> &argv, const std::string &log = {}) {
    GSubprocessLauncher *launcher =
        g_subprocess_launcher_new(log.empty() ? G_SUBPROCESS_FLAGS_NONE : G_SUBPROCESS_FLAGS_STDERR_MERGE);
    if (!log.empty()) {
        g_subprocess_launcher_set_stdout_file_path(launcher, log.c_str());
    }
    std::vector<const char *> args;
    for (const auto &arg : argv) {
        args.push_back(arg.c_str());
    }
    args.push_back(nullptr);
    GError *error = nullptr;
    GSubprocess *process = g_subprocess_launcher_spawnv(launcher, args.data(), &error);
    g_object_unref(launcher);
    if (!process) {
        std::fprintf(stderr, "键道: cannot run %s: %s\n", argv[0].c_str(), error->message);
        g_error_free(error);
        return -1;
    }
    int status = 1;
    if (g_subprocess_wait(process, nullptr, &error)) {
        if (g_subprocess_get_if_exited(process)) {
            status = g_subprocess_get_exit_status(process);
        }
    } else {
        std::fprintf(stderr, "键道: lost %s: %s\n", argv[0].c_str(), error->message);
        g_error_free(error);
    }
    g_object_unref(process);
    return status;
}

int install(const Setup &setup) {
    if (!lockUpdater()) {
        return 0;
    }
    State state = loadState();
    if (!newerRelease(state, kVersion)) {
        // Nothing newer than this updater, which is what is installed: the
        // menu that asked is an older build's, still running until the
        // framework restarts.
        state.installed = runningTag();
        saveState(state);
        notify("键道输入法已更新到 " + runningTag(), kRestartHint);
        return 0;
    }
    if (!installable(setup, state)) {
        const std::string page = releasePage(state.latest);
        if (!openExternally(page)) {
            notify("发现新版本 " + state.latest, "请前往发布页面下载：\n" + page);
        }
        return 0;
    }

    // A directory of its own, emptied first: what an earlier attempt left.
    const std::string updates = files::cacheDirectory() + "/updates";
    std::error_code ignored;
    std::filesystem::remove_all(updates, ignored);
    files::makeDirectories(updates);
    const std::string archive = updates + "/" + state.tarball.name;
    // The tarball's top directory, named as the tarball is.
    const std::string script = updates + "/" +
                               state.tarball.name.substr(0, state.tarball.name.size() - std::strlen(".tar.xz")) +
                               "/install.sh";
    const std::string log = updates + "/install.log";

    setBusy(state, Busy::Downloading);
    std::string failure = download(setup, state.tarball, archive);
    if (failure.empty() && run({"tar", "-xJf", archive, "-C", updates}) != 0) {
        failure = "无法解开安装包";
    }
    if (failure.empty() && access(script.c_str(), R_OK) != 0) {
        failure = "安装包中没有 install.sh";
    }
    if (!failure.empty()) {
        setBusy(state, Busy::None);
        std::fprintf(stderr, "键道: update download failed: %s\n", failure.c_str());
        notify("下载安装包失败", failure + "\n可以稍后再试，或手动前往发布页面下载。");
        return 1;
    }

    setBusy(state, Busy::Installing);
    // Read by the shell, not started as a program itself: SELinux, as
    // openSUSE and Fedora have it, lets nothing in a home directory begin a
    // session as root.
    std::vector<std::string> argv;
    if (!setup.sudo.empty()) {
        argv.push_back(setup.sudo);
    }
    argv.insert(argv.end(), {"/bin/sh", script});
    const int status = run(argv, log);
    if (status == 0) {
        state.installed = state.latest;
        setBusy(state, Busy::None);
        std::filesystem::remove_all(updates, ignored);
        notify("键道输入法已更新到 " + state.latest, kRestartHint);
        return 0;
    }
    setBusy(state, Busy::None);
    std::fprintf(stderr, "键道: %s exited with %d; its output is in %s\n", script.c_str(), status, log.c_str());
    // What a user can run instead.
    const std::string byHand = "sudo sh " + script;
    // pkexec's own: 126, the request dismissed; 127, no authorization — no
    // authentication agent in this session, most often.
    switch (status) {
    case -1:
        notify("无法获得管理员权限", "没有找到 pkexec。请在终端中运行：\n" + byHand);
        break;
    case 126:
        notify("没有安装新版本", "没有获得管理员授权。可以从输入法菜单重试，或在终端中运行：\n" + byHand);
        break;
    case 127:
        notify("无法获得管理员权限", "没能取得管理员授权，详见 " + log + "。请在终端中运行：\n" + byHand);
        break;
    default:
        notify("安装新版本失败", "安装程序出错（退出码 " + std::to_string(status) + "），详见 " + log + "。");
        break;
    }
    return 1;
}

int usage() {
    std::fprintf(stderr, "usage: ime-jd-update check [--interactive] | install | --version\n");
    return 2;
}

} // namespace

int main(int argc, char **argv) {
    const std::vector<std::string> args(argv + 1, argv + argc);
    if (args == std::vector<std::string>{"--version"}) {
        std::printf("%s\n", kVersion);
        return 0;
    }
    if (args == std::vector<std::string>{"check"}) {
        return check(setup(), false);
    }
    if (args == std::vector<std::string>{"check", "--interactive"}) {
        return check(setup(), true);
    }
    if (args == std::vector<std::string>{"install"}) {
        return install(setup());
    }
    return usage();
}
