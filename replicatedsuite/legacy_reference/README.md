# Legacy Reference

此目录以及仍保留在原工程目录中的 Legacy UI / Service / Professional Module 源码仅用于迁移行为核对。

- 不进入当前 `toc.g`。
- 不拥有 V3 Runtime 生命周期。
- 不允许新功能继续向 Legacy 路径写代码。
- 迁移时只读取真实业务规则、API 调用经验、用户配置语义和已验证数据流。
- V3 Feature 必须重新声明 Authority、API 依赖、Persistence、Projection 与 Widget 生命周期。

`core/rs_runtime_legacy.lua` 是硬切 V3 前 Runtime 的冻结参考副本。

`globals_archive/` preserves the removed root-level `globals/` sources for migration evidence only. Active V3 native access is owned by `replicatedsuite/native/`.
