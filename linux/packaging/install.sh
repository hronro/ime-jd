#!/bin/sh
# Installs 键道 from this tarball: the Fcitx 5 addon and the IBus engine
# both, at the same fixed paths on every distro, since each is loaded only by
# its own framework. The list of what went where is kept with them, for
# uninstall.sh. Run as root.
set -eu

here=$(cd "$(dirname "$0")" && pwd)

if [ "$(id -u)" -ne 0 ]; then
    echo "此脚本需要以 root 身份运行：sudo $0" >&2
    exit 1
fi

# A package of 键道 owns the same files; mixing the two leaves one of them
# broken on removal.
for package in ime-jd-fcitx5 ime-jd-ibus; do
    if { command -v dpkg-query >/dev/null && dpkg-query -W -f '${Status}' "$package" 2>/dev/null | grep -q '^install ok'; } ||
        { command -v rpm >/dev/null && rpm -q "$package" >/dev/null 2>&1; } ||
        { command -v pacman >/dev/null && pacman -Q "$package" >/dev/null 2>&1; }; then
        echo "已经以软件包的形式安装了 $package，请先卸载它，再使用本安装包。" >&2
        exit 1
    fi
done

echo "正在安装键道输入法……"
while IFS= read -r path; do
    if [ -x "$here/files/$path" ]; then mode=0755; else mode=0644; fi
    install -D -m "$mode" "$here/files/$path" "/$path"
done < "$here/files.txt"
install -m 0644 "$here/files.txt" /usr/lib/ime-jd/files.txt
install -m 0755 "$here/uninstall.sh" /usr/lib/ime-jd/uninstall.sh

if command -v gtk-update-icon-cache >/dev/null && [ -e /usr/share/icons/hicolor/index.theme ]; then
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi

cat <<'EOF'

键道输入法安装成功。

请重启输入法框架（Fcitx 5：fcitx5 -r；IBus：ibus restart），或注销后重新登录，
然后添加「键道」：
    Fcitx 5：Fcitx 5 配置 > 输入法 > 键道
    GNOME：设置 > 键盘 > 输入源 > 添加 > 汉语（中国）> 键道

卸载：sudo /usr/lib/ime-jd/uninstall.sh
EOF
