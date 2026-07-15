# 键道输入法 (ime-jd)

[键道输入方案](https://xkinput.github.io) 的独立原生实现。自带核心引擎与各平台前端，**开箱即用**，完全离线运行，不依赖 RIME 等第三方输入法框架。

## 🚀 当前支持平台
- 🍏 **macOS** — 基于 Input Method Kit (IMK) 的原生输入法
- 🪟 **Windows** — 基于 Text Services Framework (TSF) 的原生输入法
- 📱 **iOS / iPadOS** — 基于 Keyboard Extension 的原生输入法，**无需「完全访问权限」（Full Access）**
- 🤖 **Android** — 基于 InputMethodService 的原生输入法
- 💻 **CLI** — 用于快速调试与方案体验的终端前端

## 💡 设计原则

* **极致性能**

  流畅、无卡顿的打字体验是输入法的核心。本项目核心引擎使用 **Zig** 编写，无 GC（垃圾回收），词库在编译期直接构建；运行期零解析、零拷贝、**零动态内存分配（Zero Allocation）**。即使在极低配置的设备上也能丝滑运行，冷启动瞬间完成。
* **极简安装**

  下载即用，无需配置 RIME 环境、手动部署方案或同步词库。我们坚信“零门槛”的安装过程是良好用户体验的起点。
* **原生界面**

  各平台前端均采用原生底层技术打造，UI 设计风格严格适配宿主系统，和系统自带输入法风格保持一致。
* **轻量纯粹**

  从底层完全重构，无历史包袱，无任何运行时依赖。这使得输入法安装包体积极小，代码结构清晰单纯。
* **零配置（Zero-Config）**
  
  我们仅提供一套足够简单、好用的默认配置。这不仅能大幅降低代码复杂度以提升稳定性，也能让用户免受繁琐调优的困扰。
* **专注中文输入**

  不考虑支持非中文的输入（如英文），因为这些语言往往有更出色的原生输入法。得益于极速的架构设计，本项目在切换输入法（冷启动）时几乎瞬时就绪，多输入法混用切换毫无割裂感。

## 🚫 本项目不适合的人群

如果你需要以下功能：
- 单键 / 并击模式
- 自定义主题 / 皮肤
- 自定义词库 / 用户词库扩展
- 复杂的 Lua 脚本、挂件等高级扩展能力

**推荐使用基于 RIME 的方案**：[xkinput/KeyTao](https://github.com/xkinput/KeyTao)。

> 本项目更适合追求 **极致性能、极简依赖、即装即用、轻量稳定** 的键道用户。

## 📦 安装指南

前往 [GitHub Releases](https://github.com/hronro/ime-jd/releases/latest) 下载对应平台的安装包：

- **Windows**: 下载 `jd-ime-{版本号}-windows-{架构}.zip`
- **macOS**: 下载 `jd-ime-{版本号}-macos-{架构}.pkg`
- **Android**: 下载 `jd-ime-{版本号}-android-{架构}.apk` 
- **iOS**: 下载 `jd-ime-{版本号}-ios.ipa` *(注：iOS 用户需要使用 Sideload 工具进行自签安装)*

## 🤝 致谢

- 键道输入方案原作者**吅吅大山**。
- [xkinput/KeyTao](https://github.com/xkinput/KeyTao) 项目。

## 📄 许可证

GPL-3.0，详见 [LICENSE](./LICENSE)。
