#!/bin/sh
# Installs 键道 from this tarball: the Fcitx 5 addon and the IBus engine
# both, at the same fixed paths on every distro, since each is loaded only by
# its own framework; and the user-dictionary editor, where GTK 4 is there for
# it. The list of what went where is kept with them, for uninstall.sh. Over
# an earlier install — an update, by hand or by the update check — what that
# had and this has not is removed. Run as root.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
list=/usr/lib/ime-jd/files.txt

if [ "$(id -u)" -ne 0 ]; then
    echo "此脚本需要以 root 身份运行：sudo $0" >&2
    exit 1
fi

# A package of 键道 owns the same files; mixing the two leaves one of them
# broken on removal.
for package in ime-jd-fcitx5 ime-jd-ibus ime-jd-userdict; do
    if { command -v dpkg-query >/dev/null && dpkg-query -W -f '${Status}' "$package" 2>/dev/null | grep -q '^install ok'; } ||
        { command -v rpm >/dev/null && rpm -q "$package" >/dev/null 2>&1; } ||
        { command -v pacman >/dev/null && pacman -Q "$package" >/dev/null 2>&1; }; then
        echo "已经以软件包的形式安装了 $package，请先卸载它，再使用本安装包。" >&2
        exit 1
    fi
done

install_files() {
    while IFS= read -r path; do
        if [ -x "$here/files/$path" ]; then mode=0755; else mode=0644; fi
        install -D -m "$mode" "$here/files/$path" "/$path"
    done < "$1"
}

previous=$(cat "$list" 2>/dev/null || true)

echo "正在安装键道输入法……"
install_files "$here/files.txt"
installed=$(cat "$here/files.txt")

# The editor runs where the libraries it links to are found: GTK 4, and what
# it brings.
editor=$here/files/usr/bin/ime-jd-userdict
if ldd "$editor" >/dev/null 2>&1 && ! ldd "$editor" | grep -q 'not found'; then
    install_files "$here/editor.txt"
    installed=$(printf '%s\n%s' "$installed" "$(cat "$here/editor.txt")")
    editor_note=
else
    editor_note="

没有安装用户自造词编辑器：它需要 GTK 4。从发行版装上 GTK 4 后重新运行本安装包即可；
在此之前，输入法菜单中的「用户自造词…」会用文本编辑器打开词库文件。"
fi
printf '%s\n' "$installed" > "$list"
chmod 0644 "$list"
install -m 0755 "$here/uninstall.sh" /usr/lib/ime-jd/uninstall.sh

printf '%s\n' "$previous" | while IFS= read -r path; do
    if [ -n "$path" ] && ! printf '%s\n' "$installed" | grep -qxF "$path"; then
        rm -f "/$path"
    fi
done

if command -v gtk-update-icon-cache >/dev/null && [ -e /usr/share/icons/hicolor/index.theme ]; then
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi

cat <<EOF

键道输入法安装成功。$editor_note

请重启输入法框架（Fcitx 5：fcitx5 -r；IBus：ibus restart），或注销后重新登录，
然后添加「键道」：
    Fcitx 5：Fcitx 5 配置 > 输入法 > 键道
    GNOME：设置 > 键盘 > 输入源 > 添加 > 汉语（中国）> 键道

卸载：sudo /usr/lib/ime-jd/uninstall.sh
EOF
