#!/bin/sh
# Removes what install.sh installed, by the list it kept in /usr/lib/ime-jd.
# Each user's phrases and settings, in ~/.config/ime-jd, are left alone.
# Run as root.
set -eu

list=/usr/lib/ime-jd/files.txt

if [ "$(id -u)" -ne 0 ]; then
    echo "此脚本需要以 root 身份运行：sudo $0" >&2
    exit 1
fi
if [ ! -e "$list" ]; then
    echo "没有找到 $list：键道输入法似乎没有用安装包安装过。" >&2
    exit 1
fi

while IFS= read -r path; do
    rm -f "/$path"
done < "$list"
rm -f "$list" /usr/lib/ime-jd/uninstall.sh
# Only the directories that were 键道's own; the frameworks' stay.
rmdir /usr/lib/ime-jd /usr/share/ibus-ime-jd/icons /usr/share/ibus-ime-jd 2>/dev/null || true

if command -v gtk-update-icon-cache >/dev/null && [ -e /usr/share/icons/hicolor/index.theme ]; then
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi

echo "键道输入法已卸载。重启输入法框架或注销后重新登录即可生效。"
