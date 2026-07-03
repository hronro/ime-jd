# jd (Swift bindings)

libjd 核心引擎的 Swift 安全封装，供 `macos/` 与 `ios/` 两个前端**源文件级共享**：两边的 `project.yml` 直接把本目录列为 source path（XcodeGen 支持项目目录外的相对路径），同一份文件编译进各自的 target——不经过 SPM package，也没有软链接。此前这三个文件在两个项目里是靠注释纪律人肉同步的逐字节拷贝。

```yaml
# macos/project.yml / ios/project.yml
sources:
  - path: ../bindings/swift
```

## 内容

- **`Engine.swift`** — `jd_context` 的 RAII 封装（`deinit` 调 `jd_deinit`），每个方法返回深拷贝后的 `QuerySnapshot`。
- **`QuerySnapshot.swift`** — owned 的结果快照。`copy` 在返回前把 C API 的借用指针全部拷贝为 Swift `String`（生命周期契约见 `core/docs/integration.md`），并实现"当前页可见候选数"的取余运算。
- **`KeyAction.swift`** — 按键语义动作枚举，各前端的 key gate / dispatch 层共用。

平台相关的部分不在这里：macOS 的 `KeyGate`/`Composition`/IMK 控制器在 `macos/JdIME/`，iOS 的 `InputSession` 在 `ios/Keyboard/Engine/`——两者的分发语义有刻意的平台差异（macOS 空结果回传宿主，iOS 插入字面量），不应合并。

## 前提

`import Libjd` 依赖各 target 的 `SWIFT_INCLUDE_PATHS` 指向 `core/include`（module map），两个项目的 project.yml 已配置。

## 测试

引擎语义测试在各前端的测试 target 里：`macos/JdIMETests/EngineSmokeTests.swift` 与 `ios/KeyboardTests/InputSessionTests.swift`——它们分别通过本目录的共享封装驱动真实引擎。
