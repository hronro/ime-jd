# 键道输入法 (jd-ime)

[键道输入方案](https://xkinput.github.io)的一个独立实现，自带核心引擎和各平台前端，**开箱即用**，不依赖第三方输入法框架。

目前支持：

- **macOS** — 基于 Input Method Kit (IMK) 的原生输入法
- **Windows** — 基于 Text Services Framework (TSF) 的原生输入法
- **iOS / iPadOS** — 基于键盘扩展（Keyboard Extension）的原生输入法，**完全无需「完全访问权限」（Full Access）**，离线运行、保护隐私
- **CLI** — 用于调试和体验的终端前端

## 特点

- **部署简单**：下载安装包双击即可，无需安装 RIME、配置方案、部署词库等繁琐步骤。
- **高性能**：核心引擎使用 Zig 编写，词库在构建期编译为紧凑的 trie 二进制；运行期零解析、零拷贝、无动态内存分配。
- **轻巧**：无运行时依赖；整个输入法的安装体积非常小。
- **冷启动快**：所有词库数据在编译期就已经打包好，启动时不需要解析任何文件，首次按键即可响应。

## 取舍

本项目追求零配置。我们认为仅支持一套足够简单好用的默认配置，不仅能使项目代码复杂度简化以实现更高的稳定性，同时也能省去用户调试各种配置的繁琐。

如果你需要：

- 单键／并击模式
- 自定义主题／皮肤
- 自定义词库 / 用户词库
- 复杂的方案脚本、过滤器、挂件等扩展能力

推荐使用基于 RIME 的方案：[xkinput/KeyTao](https://github.com/xkinput/KeyTao)。

本项目更适合追求**最小依赖、即装即用、轻量稳定**的用户。

## 安装

前往 [GitHub Releases](https://github.com/hronro/ime-jd/releases) 下载对应平台的安装包即可。

## 致谢

- 键道输入方案原作者**吅吅大山**。
- [xkinput/KeyTao](https://github.com/xkinput/KeyTao) 项目。

## 许可证

GPL-3.0，详见 [LICENSE](./LICENSE)。
