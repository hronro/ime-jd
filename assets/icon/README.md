# 键道图标

一枚朱砂印：160 视野内的圆角方印、阴刻边框、白色「键」字。两种古典刻法对应两种技术形态：

- **白文**（红底白字，`jd.svg`）— 各平台的彩色应用图标。
- **朱文**（单色线刻，`jd-mono.svg`）— 单色场景：Android 13 主题图标。
- **模板刀版**（黑色 + alpha 镂空，`jd-menu.svg`）— macOS 菜单栏 / 输入法菜单，系统随明暗自动着色。

小尺寸（16/32 px）另有专门裁切 `jd-small.svg`：去边框、平涂红底、字形加大加粗。边框在 16 px 只剩噪点，这是刻意的降级而非缩放事故。模板刀版即该裁切的镂空版。

## 字形来源与许可

「键」的轮廓取自 [霞鹜文楷](https://github.com/lxgw/LxgwWenKai)（LXGW WenKai Medium v1.522，OFL-1.1）。
构建时用 CoreText 将字形转成路径（见 `icontool.swift`），产物只含曲线数据，不内嵌也不再分发字体本身 —— OFL 允许将轮廓嵌入文档/图像，与本项目的 GPL-3.0 分发不冲突。字体不入库，由 `generate.sh` 按固定 URL + SHA-256 下载缓存。

## 重新生成

```sh
bash assets/icon/generate.sh
```

仅限 macOS（需要 CoreText 提取字形、`iconutil` 打包 icns），另需 `rsvg-convert`（`brew install librsvg`）。脚本产出并覆盖：

| 产物 | 说明 |
| --- | --- |
| `macos/JdIME/jd.icns` | `Info.plist` 的 `CFBundleIconFile`（访达 / 安装器）；16/32 pt 为小尺寸裁切，128 pt 起为标准 Big Sur 网格（824/1024 圆角方块 + 投影） |
| `macos/JdIME/jd-menu.tiff` | 菜单栏输入源图标：`tsInputMethodIconFileKey` + `TISIconIsTemplate`（Apple 自家 AinuIM / PluginIM 的做法），16 + 32@2x 双页 TIFF 镂空块，系统按菜单栏明暗着色 |
| `ios/App/Assets.xcassets/AppIcon.appiconset/` | 单尺寸 1024，已去 alpha 通道（App Store 要求） |
| `android/.../mipmap-anydpi-v26/` + `drawable/` + `values/` | 自适应图标三层：纯色红底 / 白字前景 / 单色层（Android 13 主题图标）。字形墨盒 46 dp，居中于 66 dp 安全圆内 |
| `android/.../mipmap-{m,h,x,xx,xxx}dpi/ic_launcher.png` | minSdk 24 的传统图标（48–192 px；96 px 以下用小尺寸裁切） |
| `windows/jd.ico` | 嵌入 TSF DLL（`build.rs` 的 `1 ICON`），`RegisterProfile` 以 uIconIndex 0 引用；16–48 为 BMP 表项，256 为 PNG 表项 |

几何参数（字形墨盒的定位与缩放、边框、配色）集中在 `generate.sh` 第 3 步与 `compose.py` 顶部。
