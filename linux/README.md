# 键道输入法 for Linux

键道 for the two input method frameworks Linux desktops use: a **Fcitx 5** addon and an **IBus** engine. Use the one for the framework you run — IBus is GNOME's default; Fcitx 5 is the usual choice on KDE and on window managers such as Sway, Hyprland and niri. Both are thin C++ frontends over one shared layer (`common/`) and `libjd`, linked statically. The framework draws the candidate window and the input method's menu, so 键道 looks like the rest of the desktop. How each switches between 中 and 英 follows its framework — see [中 and 英](#中-and-英). Besides the built-in dictionary it carries the user's own phrases, which a window of their own edits: `ime-jd-userdict`, in Vala over GTK 4 — see [User dictionary](#user-dictionary). Installed from the generic tarball, it also checks for new releases and installs them; distro packages are left to their package managers — see [Updates](#updates).

## Requirements

- Fcitx 5.0.14 or newer, or IBus 1.5.26 or newer, and for the user-dictionary editor GTK 4.6 or newer — the versions in Ubuntu 22.04, the oldest release builds target.
- For building: Meson 0.61+, Ninja, GCC with C++20 (Fcitx 5.1's headers need it; Ubuntu 22.04's GCC 11 will do), pkg-config, [Zig](https://ziglang.org/) (used to build the `libjd` core), the frameworks' development files, and for the editor Vala and GTK 4's:
  - Debian/Ubuntu: `libfcitx5core-dev fcitx5-modules-dev libibus-1.0-dev valac libgtk-4-dev`
  - Fedora and openSUSE: `fcitx5-devel ibus-devel vala gtk4-devel`
  - Arch: `fcitx5 ibus vala gtk4`
  - Alpine: `fcitx5-dev ibus-dev vala gtk4.0-dev`

  `scripts/install-deps.sh build` installs them, and a toolchain, with the distro's package manager. The update check's updater, built only with `-Dupdate_check=true`, needs GIO's development files besides, which IBus's bring.
- At run time, the updater loads libcurl (`libcurl.so.4`, or Debian's and Ubuntu's `libcurl-gnutls.so.4`), which every distro has, and runs the tarball's `install.sh` through pkexec.

Build with GCC's C++ library, not `zig c++`: the Fcitx 5 addon runs inside the fcitx5 process and exchanges `std::string` and friends with it, so it must use the same libstdc++. `zig c++` builds against LLVM's libc++, and the addon would not load.

## Build

From the repo root:

```
meson setup linux/build linux --prefix=/usr --buildtype=release
meson compile -C linux/build
meson test -C linux/build
```

Meson runs the Zig core build itself, for the target's baseline CPU. Options, set with `-Dname=value`:

| Option | Default | |
|---|---|---|
| `fcitx5`, `ibus` | `auto` | Build that frontend: `enabled`, `disabled`, or `auto` — when its development files are there. |
| `editor` | `auto` | Build the user-dictionary editor, likewise: when Vala and GTK 4's development files are there. |
| `tests` | `true` | Build the shared layer's tests, and the editor's. |
| `libjd` | — | A prebuilt `libjd.a` instead of running Zig. It must be position-independent, as `core/build.zig` builds it for Linux, since the Fcitx 5 addon is a shared object. |
| `fcitx5_addon_dir` | Fcitx 5's addon directory | Elsewhere, the addon's config names the library by absolute path, which Fcitx 5 loads as is. |
| `ibus_engine_dir` | `libexecdir` | Where the IBus engine program goes; its component file points there. |
| `update_check` | `false` | Build the update check: the updater, `ime-jd-update` in `libexecdir`, and the menus' update items. Only the generic tarball has it; distro packages are their package managers' to update. See [Updates](#updates). |

## Install

```
sudo meson install -C linux/build
```

| Frontend | Files |
|---|---|
| Fcitx 5 | `libime-jd.so` in Fcitx 5's addon directory (`/usr/lib/fcitx5`, `/usr/lib/x86_64-linux-gnu/fcitx5`, `/usr/lib64/fcitx5`, …); `addon/ime-jd.conf` and `inputmethod/ime-jd.conf` in `/usr/share/fcitx5`; the icon `fcitx-ime-jd` in the hicolor theme |
| IBus | `ibus-engine-ime-jd`; `ime-jd.xml` in `/usr/share/ibus/component`; `/usr/share/ibus-ime-jd/icons/ime-jd.svg` |
| Editor | `ime-jd-userdict` in `bindir`; `io.github.hronro.ImeJd.UserDict.desktop` in `/usr/share/applications`, and its icon in the hicolor theme |
| Update check | `ime-jd-update` in `libexecdir`, with `-Dupdate_check=true` |

Fcitx 5's and IBus's files go to those frameworks' own directories, wherever the prefix points, since that is the only place they look; the prefix decides where the IBus engine program, the editor and the icons go. Both frontends start the editor from where this prefix puts it, whether or not it was built with them.

Then restart the framework (`fcitx5 -r`, or `ibus restart`) or log out and back in, and add 键道:

- Fcitx 5: **Fcitx 5 Configuration → Input Method**, add **键道**.
- GNOME: **Settings → Keyboard → Input Sources → Add → Chinese (China) → 键道**.

## Uninstall

```
sudo ninja -C linux/build uninstall
```

Each user's phrases and settings, in `~/.config/ime-jd/`, are left alone.

## Packages

Each release carries a package of each frontend and of the editor for each distro family, and a tarball for the rest. `packaging/build.sh` makes them, in the oldest distro of each libc, so that they run on every newer one:

| Built on | Assets |
|---|---|
| Ubuntu 22.04 (glibc) | `jd-ime-v{version}-linux-{arch}-{fcitx5,ibus,userdict}.deb`, `.rpm` and `.pkg.tar.zst`, and the tarball `jd-ime-v{version}-linux-{arch}.tar.xz` |
| Alpine 3.22 (musl) | `jd-ime-v{version}-alpine-{arch}-{fcitx5,ibus,userdict}.apk` |

Each frontend's package, `ime-jd-fcitx5` or `ime-jd-ibus`, depends on its framework, which the package manager installs with it. The Fcitx 5 addon goes to the distro's addon directory: `/usr/lib/<multiarch>/fcitx5` in the `.deb`, `/usr/lib64/fcitx5` in the `.rpm`, and `/usr/lib/fcitx5` in the Arch package and the `.apk`. The IBus engine goes to `/usr/libexec` in all of them. The editor's package, `ime-jd-userdict`, depends on GTK 4 (and on Alpine on `mesa-gles`, the GLES library Alpine's GTK 4 leaves out, without which a GTK 4 window aborts at start), and the frontends' recommend it — an optional dependency to Arch's pacman; an `.apk` has no such field. The three packages share no files, so all can be installed. The tarball holds all three at the same paths on every distro, with the frontends' programs in `/usr/lib/ime-jd`, from where Fcitx 5 loads the addon by its absolute path, and beside them the update check's updater: the tarball alone is built with it. Its `install.sh` installs the editor, listed apart in `editor.txt`, only where the libraries it links to are found — where GTK 4 is installed — and keeps a list of what it installed, for `/usr/lib/ime-jd/uninstall.sh`. Run over an earlier install, as an update does, it removes what that had and this one has not.

To build them as CI does — here for glibc on x86_64; [nfpm](https://nfpm.goreleaser.com) comes in from outside the container:

```
zig build --build-file core/build.zig -Doptimize=fast -Dtarget=x86_64-linux --prefix /tmp/libjd
linux/scripts/install-nfpm.sh /tmp/nfpm
mkdir -p dist
podman run --rm -v "$PWD:/src:ro" -v /tmp/libjd/lib:/libjd:ro -v /tmp/nfpm/nfpm:/usr/local/bin/nfpm:ro \
    -v "$PWD/dist:/dist" docker.io/library/ubuntu:22.04 sh -euc '
    /src/linux/scripts/install-deps.sh build
    /src/linux/packaging/build.sh /dist /libjd/libjd.a'
```

CI (`.github/workflows/build-on-push.yml`) then installs the packages on clean Ubuntu 22.04, Debian 13, Fedora, openSUSE Tumbleweed, Arch and Alpine systems, the way a user would (`scripts/install-packages.sh`), and the tarball on Fedora, and runs both frontends end to end on each, and the editor as far as it goes without a display.

## 中 and 英

Each frontend switches the way its framework does, and 键道 types no English of its own where the framework already switches:

- **Fcitx 5** switches for it. By default, Left Shift toggles between the keyboard layout and 键道, and the tray icon shows which is active; the key is set in Fcitx 5's global options, under **Hotkey**. The addon has no English mode.
- **IBus** has no such switch — GNOME changes input sources with Super+Space — and a Chinese IME there is expected to have one, as ibus-libpinyin and ibus-rime do. So the engine has Windows' rule: Shift pressed and released alone switches 中 and 英, and 键道 starts in 中. In 英 every key goes to the application as typed. GNOME shows 中 or 英 in the top bar, and IBus's own panel, on other desktops, as its tray icon, both through the engine's `InputMode` property; its menu item switches too. IBus normally runs one engine for all applications, so the mode is shared by them, unlike on Windows. An IBus engine cannot see the mouse either, so Shift held through a click (extending a selection) still counts as a switch when it is released alone.

Either way, switching while letters are typed puts them in as they are, and so does focus moving to another window. The frameworks themselves commit those letters, the preedit, to the window they were typed in: the frontends leave it to them, since an engine's own commit would follow focus to the next window. Password fields get the keys as typed.

## User dictionary

The user's own phrases, in `~/.config/ime-jd/用户自造词.txt` (`$XDG_CONFIG_HOME`), are the same UTF-8 file every client reads: one `词<TAB>编码` per line. They are off until the user turns them on, with **启用用户自造词** in the input method's menu — Fcitx 5's tray menu, or GNOME's input source menu. The switch is kept beside the phrases, in `settings.ini`:

```ini
[UserDict]
Enabled=true
```

The directory is watched, so a saved edit is rebuilt within a moment and the next composition uses it. The menu's last line says how many phrases are in use, and how many lines were skipped as invalid or ignored as duplicates. A file that cannot be loaded at all — not UTF-8, over the engine's caps — leaves the last good dictionary in use, says so on that line, and raises a desktop notification. All of this follows the macOS client (`macos/JdIME/UserDict/UserDictStore.swift`).

**用户自造词…** in the same menu opens the editor, `ime-jd-userdict` — also **键道用户自造词** in the desktop's application list. It is the macOS window (`macos/JdIME/UserDict/UserDictWindowController.swift`) in GTK 4: a table over the file, with **启用用户自造词** above it.

- The table *is* the file: every edit, addition, deletion and drag writes every row back, in table order, with one header line. Comments and blank lines are not kept.
- A cell is edited in place: double-click it, or press Return on the row; Tab moves on to the next cell, Escape drops the edit. **+** adds a row below the selection, **−** or Delete removes the selected ones, asking first for more than one. Dragging rows reorders them, which matters among phrases on the same code: they are offered in file order.
- The window validates nothing itself. It builds the file with `libjd`, as the engines do, and shows the build's notes on each row in the **状态** column: red for a line the engine skips, with why; grey for a duplicate of an earlier row or of a built-in word; orange for a phrase whose code is already taken, which works but now shares it. **移除重复词条** offers to delete the duplicates, or selects every flagged row to look at.
- **用文本编辑器打开** opens the file in the desktop's text editor, and a save there shows up in the table.

Two things differ from macOS. A row added and left empty is dropped rather than written. And a file that cannot be read — not UTF-8, unreadable — is shown as an empty table that cannot be edited, where macOS would let the first edit replace it; the text editor is the way to fix it.

One window serves the session: starting the editor again brings it forward. `ime-jd-userdict --file <path>` edits another file instead, to try the window out without touching the real phrases; such a window remembers no size and stands beside the other. The window's size is kept in `settings.ini` too, under `[UserDictWindow]`.

The editor is a package of its own. Where it is not installed, **用户自造词…** opens the file in the desktop's text editor instead, creating it with a one-line header if there is none.

## Updates

The generic tarball updates itself, as the macOS and Windows clients do (`macos/JdIME/Update/`, `windows/src/update/`); distro packages do not, being their package managers' to update. It is the build option `update_check`, which `packaging/build.sh` turns on for the tarball alone. Its menus — Fcitx 5's tray menu, GNOME's input source menu — then have macOS's two items after the version:

- **检查更新…** checks now and says what it found. While a release newer than this one is known, the item is **发现新版本 v{version}，下载并安装…** instead, and installs it. While the updater works, it says what it is doing: checking, downloading, installing.
- **自动检查更新**, on by default, has 键道 check by itself, at most once a day, when it becomes active. The switch is kept in `settings.ini`:

  ```ini
  [Update]
  CheckAutomatically=false
  ```

The work is the updater's, `/usr/lib/ime-jd/ime-jd-update`, a process of its own that the frontends start and let go (`updater/main.cpp`):

- `ime-jd-update check` reads GitHub's latest release (`https://api.github.com/repos/hronro/ime-jd/releases/latest`), sending nothing but the request and a `User-Agent` of `ime-jd-linux/{version}`, and records what it found in `~/.config/ime-jd/update.ini`, which the menus show. A newer release raises a desktop notification, once; checked from the menu, every outcome does.
- `ime-jd-update install` downloads the release's tarball for this machine to `~/.cache/ime-jd/updates`, checks it against the size and SHA-256 GitHub publishes with it, unpacks it, and runs its `install.sh` as root through pkexec: the desktop's authentication agent asks for the password, as for any administrative task. The new version runs once the framework restarts, which the notification says how to do, and until then the menu says so too. Where the request is dismissed, or cannot be made — pkexec not installed, as on openSUSE and Debian unless the `pkexec` package is, or no authentication agent, as on some window managers — the notification gives the `sudo` command for the script it unpacked. pkexec runs the script through `/bin/sh`: SELinux, as openSUSE and Fedora enforce it, lets no file in a home directory start a root session itself. A release without a tarball for this machine, or with no digest to check it by, or 键道 not installed from the tarball, opens the release page instead.

One updater runs at a time. HTTPS is the system's libcurl, loaded when needed rather than linked, since distros version its symbols each their own way; it brings the distro's certificates, and takes a proxy from the environment, as curl does.

## Tests

`meson test` runs the shared layer's tests against the real engine, and the editor's for its parts that need no display: the file format, `settings.ini`, the **状态** column's words, and the store.

`tests/e2e/run.sh` runs both frontends end to end: it starts fcitx5 and ibus-daemon, each in a D-Bus session of its own, and drives the installed frontend through the same D-Bus interfaces applications' input method modules use — keys in, committed text, preedit and candidates out. The editor's window needs a display, so of the editor it checks only that it starts. Where the update check is built, it runs the updater against a release feed it serves on the machine, with a notification service of its own and a stand-in for pkexec: what the updater records, what it says, and an install of a tarball it builds; the frontends' tests turn the automatic check off, so none asks GitHub. It needs 键道 and its editor installed to `/usr`, the frameworks, `dbus` and PyGObject (`python3-gi` and IBus's GObject introspection data), and libcurl for the updater, and it rewrites `~/.config` and `~/.cache`, so it is meant for a container:

```
zig build --build-file core/build.zig -Doptimize=fast -Dtarget=x86_64-linux --prefix /tmp/libjd
podman run --rm -v "$PWD:/src:ro" -v /tmp/libjd/lib:/libjd:ro docker.io/library/ubuntu:22.04 sh -euc '
    /src/linux/scripts/install-deps.sh build test
    meson setup /build /src/linux --prefix=/usr -Dlibjd=/libjd/libjd.a -Dupdate_check=true
    meson install -C /build
    /src/linux/tests/e2e/run.sh'
```

Ubuntu 22.04 has no Zig package, so the archive is built outside. CI runs this on Ubuntu 22.04 and on Arch, the oldest and the newest frameworks (`.github/workflows/test-on-push.yml`), and the release assets' own tests in `build-on-push.yml`: the packages, without the update check, and the tarball, with it.

## Layout

| Path | |
|---|---|
| `common/key_gate.*` | Which keys go to the engine — the macOS client's `KeyGate.swift`, with X keysyms. |
| `common/session.*` | One input context's composition, candidates and paging — the macOS `InputController` and `Composition`, with the framework behind a `Host` interface. |
| `common/user_dict.*` | The phrases file and the switch — the macOS `UserDictStore`, watched with inotify. |
| `common/files.*` | The files in `~/.config/ime-jd`: reading them, replacing them in one rename, and `settings.ini`. |
| `common/update.*` | The update check's shared side: the release feed's rules, `update.ini`, and the menus' item, switch and daily check — the macOS `UpdateFeed` and `UpdateManager`. |
| `common/sha256.*` | SHA-256, which the updater checks downloads with. |
| `common/engine.*` | `libjd`'s context, and the user-dictionary blob it reads. |
| `fcitx5/` | The Fcitx 5 addon and its config files. |
| `ibus/` | The IBus engine, its process and its component file. |
| `updater/` | The tarball's updater, `ime-jd-update`, and the libcurl it loads. |
| `editor/` | The user-dictionary editor: the file, `settings.ini` and the store (`file.vala`, `ini.vala`, `store.vala`), the **状态** column's words (`problem.vala`), the table (`row.vala`, `window.vala`) and its prompts (`prompt.vala`); `jd.vapi` binds the part of `libjd` it calls. |
| `tests/` | Tests for `common/`, run against the real engine, and for the editor's parts that need no display. |
| `tests/e2e/` | Both frontends in real fcitx5 and ibus-daemon, and the updater against a feed of its own. |
| `packaging/` | `build.sh`, which makes the release assets, and the tarball's `install.sh` and `uninstall.sh`. |
| `scripts/` | What CI's containers run: each distro's build and test dependencies, nfpm, and installing the built packages. |
