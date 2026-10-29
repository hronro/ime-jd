# 键道输入法 for Linux

键道 for the two input method frameworks Linux desktops use: a **Fcitx 5** addon and an **IBus** engine. Use the one for the framework you run — IBus is GNOME's default; Fcitx 5 is the usual choice on KDE and on window managers such as Sway, Hyprland and niri. Both are thin C++ frontends over one shared layer (`common/`) and `libjd`, linked statically. The framework draws the candidate window and the input method's menu, so 键道 looks like the rest of the desktop. How each switches between 中 and 英 follows its framework — see [中 and 英](#中-and-英). Besides the built-in dictionary it carries the user's own phrases — see [User dictionary](#user-dictionary).

## Requirements

- Fcitx 5.0.14 or newer, or IBus 1.5.26 or newer — the versions in Ubuntu 22.04, the oldest release builds target.
- For building: Meson 0.61+, Ninja, GCC with C++20 (Fcitx 5.1's headers need it; Ubuntu 22.04's GCC 11 will do), pkg-config, [Zig](https://ziglang.org/) (used to build the `libjd` core), and the frameworks' development files:
  - Debian/Ubuntu: `libfcitx5core-dev fcitx5-modules-dev libibus-1.0-dev`
  - Fedora: `fcitx5-devel ibus-devel`
  - Arch: `fcitx5 ibus`

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
| `tests` | `true` | Build the shared layer's tests. |
| `libjd` | — | A prebuilt `libjd.a` instead of running Zig. It must be position-independent, as `core/build.zig` builds it for Linux, since the Fcitx 5 addon is a shared object. |
| `fcitx5_addon_dir` | Fcitx 5's addon directory | Elsewhere, the addon's config names the library by absolute path, which Fcitx 5 loads as is. |
| `ibus_engine_dir` | `libexecdir` | Where the IBus engine program goes; its component file points there. |

## Install

```
sudo meson install -C linux/build
```

| Frontend | Files |
|---|---|
| Fcitx 5 | `libime-jd.so` in Fcitx 5's addon directory (`/usr/lib/fcitx5`, `/usr/lib/x86_64-linux-gnu/fcitx5`, `/usr/lib64/fcitx5`, …); `addon/ime-jd.conf` and `inputmethod/ime-jd.conf` in `/usr/share/fcitx5`; the icon `fcitx-ime-jd` in the hicolor theme |
| IBus | `ibus-engine-ime-jd`; `ime-jd.xml` in `/usr/share/ibus/component`; `/usr/share/ibus-ime-jd/icons/ime-jd.svg` |

Fcitx 5's and IBus's files go to those frameworks' own directories, wherever the prefix points, since that is the only place they look; the prefix decides where the IBus engine program and the icons go.

Then restart the framework (`fcitx5 -r`, or `ibus restart`) or log out and back in, and add 键道:

- Fcitx 5: **Fcitx 5 Configuration → Input Method**, add **键道**.
- GNOME: **Settings → Keyboard → Input Sources → Add → Chinese (China) → 键道**.

## Uninstall

```
sudo ninja -C linux/build uninstall
```

Each user's phrases and settings, in `~/.config/ime-jd/`, are left alone.

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

**用户自造词…** in the same menu opens the file in the desktop's text editor, creating it with a one-line header if there is none; Linux has no phrase-list window yet. The directory is watched, so a saved edit is rebuilt within a moment and the next composition uses it. The menu's last line says how many phrases are in use, and how many lines were skipped as invalid or ignored as duplicates. A file that cannot be loaded at all — not UTF-8, over the engine's caps — leaves the last good dictionary in use, says so on that line, and raises a desktop notification. All of this follows the macOS client (`macos/JdIME/UserDict/UserDictStore.swift`).

## Tests

`meson test` runs the shared layer's tests against the real engine.

`tests/e2e/run.sh` runs both frontends end to end: it starts fcitx5 and ibus-daemon, each in a D-Bus session of its own, and drives the installed frontend through the same D-Bus interfaces applications' input method modules use — keys in, committed text, preedit and candidates out. It needs 键道 installed to `/usr`, the frameworks, `dbus` and PyGObject (`python3-gi` and IBus's GObject introspection data), and it rewrites `~/.config`, so it is meant for a container:

```
zig build --build-file core/build.zig -Doptimize=fast -Dtarget=x86_64-linux -Dcpu=baseline --prefix /tmp/libjd
podman run --rm -v "$PWD:/src:ro" -v /tmp/libjd/lib:/libjd:ro docker.io/library/ubuntu:22.04 sh -c '
    apt-get update && apt-get install -y --no-install-recommends \
        g++ meson ninja-build pkg-config libfcitx5core-dev fcitx5-modules-dev libibus-1.0-dev \
        fcitx5 ibus dbus python3-gi gir1.2-ibus-1.0 &&
    meson setup /build /src/linux --prefix=/usr -Dlibjd=/libjd/libjd.a &&
    meson install -C /build && /src/linux/tests/e2e/run.sh'
```

Ubuntu 22.04 has no Zig package, so the archive is built outside.

## Layout

| Path | |
|---|---|
| `common/key_gate.*` | Which keys go to the engine — the macOS client's `KeyGate.swift`, with X keysyms. |
| `common/session.*` | One input context's composition, candidates and paging — the macOS `InputController` and `Composition`, with the framework behind a `Host` interface. |
| `common/user_dict.*` | The phrases file and the switch — the macOS `UserDictStore`, watched with inotify. |
| `common/engine.*` | `libjd`'s context, and the user-dictionary blob it reads. |
| `fcitx5/` | The Fcitx 5 addon and its config files. |
| `ibus/` | The IBus engine, its process and its component file. |
| `tests/` | Tests for `common/`, run against the real engine. |
| `tests/e2e/` | Both frontends in real fcitx5 and ibus-daemon. |
