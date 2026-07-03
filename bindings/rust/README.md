# jd (Rust bindings)

libjd 核心引擎的 Rust 安全封装，供 `cli/` 与 `windows/` 两个前端通过 path dependency 共享：

```toml
[dependencies]
jd = { path = "../bindings/rust" }
```

## 设计

- **所有返回值是 owned 数据**。C API 返回的指针只在同一 context 的下一次 `jd_*` 调用前有效（见 `core/docs/integration.md` 的指针生命周期契约）；封装层在返回前把 `commit`、候选值和 hint 全部拷贝为 `String`，因此 `QueryResult` 可以任意保留。
- **`&mut self` 静态强制单线程契约**。单个 `JdContext` 不允许并发调用；不同 context 完全独立。
- **`visible_count`** 是"当前页可见候选数"取余运算的唯一实现（`options_count` 是全部页的总数，非当前数组长度），各前端不应自行复制这段逻辑。
- **链接由本 crate 的 build.rs 负责**（`links = "jd"`）：优先使用 `LIBJD_PATH` 指向的预构建产物，否则调用 zig 构建 `core/`。依赖方的 build.rs 可通过 `DEP_JD_LIBDIR` / `DEP_JD_LINKAGE` 获知库目录与链接方式（CLI 用它在动态链接的开发构建里补 rpath）。

## 测试

```sh
cargo test
```

集成测试链接真实词库，覆盖 FFI 冒烟、context 独立性、结果 owned 性（跨调用保留）与分页一致性。
