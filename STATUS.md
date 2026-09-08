# 第一轮状态

更新日期：2026-09-08

基线：`cyyself/OpenTihui` commit `8ccb7a3fe788280ec71504675366c99e0abbee2b`

llama.cpp 子模块：commit `9d5d882d8cd0f0a9283d87ed5e6fe3ee0d925fb1`

## 当前构建状态

- [x] 已获取 OpenTihui 源码和锁定的 llama.cpp 子模块。
- [x] 已确认 Xcode 工程、主 App target 与 Keyboard Extension target 存在。
- [x] 已增加 `.github/workflows/ios-build.yml`，支持 push 与手动 `workflow_dispatch`。
- [x] Workflow 会构建 Metal-enabled llama.cpp XCFramework、构建 unsigned `iphoneos` Release App、打包 unsigned IPA，并在失败时保留日志。
- [ ] 尚未确认 GitHub Actions 实际构建成功：当前目录不是用户 GitHub 账号下的远程 Fork，无法替用户 push 或启动其 Actions。
- [ ] 尚未在真实 iPhone 上安装或运行：当前主机是 Windows，没有 Xcode/iOS SDK，也没有连接到本任务的真机执行通道。

因此目前不能声称“工程已成功 Build”或“IPA 已可安装”。只有用户 Fork、push，并看到 workflow 绿色通过后，才可记录 **Unsigned build succeeded**；Sideloadly 完成重新签名和安装后，才算真机安装验证成功。

## 许可证与依赖

- OpenTihui：MIT License，可修改和再分发，但分发时需保留版权与许可证文本。
- llama.cpp/ggml：Git submodule，锁定到上述提交；项目通过 `scripts/build-llama-ios.sh` 构建 XCFramework，启用 `GGML_METAL=ON`、嵌入 Metal library，并包含 `libmtmd`。
- OpenTihui 当前没有 Swift Package 依赖；llama.cpp 以本地 XCFramework 链接。
- App 最低目标为 iOS 17.0，Swift 5；README 要求 Xcode 16+。
- Qwen3-TTS Swift 包：Apache-2.0；声明 Swift 5.9、iOS 17+/macOS 14+，依赖 `mlx-swift >= 0.21.0`，其当前锁文件解析到 MLX Swift 0.30.3 与 swift-numerics 1.1.1。第一轮未接入该依赖。

## 已复用模块

- `InferenceEngine.swift`：专用串行队列、模型 load/unload、context resize/reset、token `AsyncStream`、停止生成和内存预检。
- `LlamaBridge.h/.mm`：llama.cpp/mtmd C++ 互操作、GGUF 加载、Metal/CPU 选择、采样、流式 token、上下文压缩、性能与 llama 日志。
- `ModelStore.swift`：模型扫描、Files 导入、复制/登记/删除和模型元数据。
- `DownloadManager.swift`、`RecommendedModelsSheet.swift`、`DownloadModelSheet.swift`：现有 Hugging Face/URL 下载链路。
- `ChatViewModel.swift`、`ChatView.swift`：模型生命周期、会话恢复、流式消费、停止、上下文管理和聊天 UI。
- `ConversationStore.swift`：本地聊天历史。
- `LogView.swift` 与 Bridge 日志：App 内诊断入口。

这些功能本轮未重写。

## 本轮改动

- 新增 GitHub Actions unsigned iPhone 构建和 Artifact 打包。
- 新增面向零基础 Windows 用户的 Fork、提交、Actions、Sideloadly 和故障日志说明。
- 未改动 llama.cpp Bridge、推理、模型管理、下载、流式生成、聊天历史、Keyboard 或 Cloud API 实现。

## 需要修改的模块（下一阶段）

1. 新增独立的 `CharacterProfile` 与 `CharacterStore`，沿用当前 JSON 配置存储风格。
2. 在 `ChatViewModel.resolvedSystemPrompt()` 的上游注入当前角色 prompt，不改 llama.cpp Bridge。
3. 在设置或聊天入口增加轻量角色选择/编辑页；角色切换时走现有 reset/replay 生命周期。
4. 是否隐藏 Keyboard Extension / Remote API 必须在第一轮 CI 绿灯后单独、小步修改，并分别再次构建；当前不删除 target。

## Qwen3-TTS 集成位置建议

第一轮按要求不接入、不实现 smoke test。下一阶段建议：

- 以 Swift Package 产品 `Qwen3TTS` 接入主 App target；OpenTihui 的 llama.cpp 是本地 XCFramework，静态依赖图上未发现直接包版本冲突。
- 新建独立 `TTS/TTSEngine.swift`、`TTS/Qwen3TTSEngine.swift`、`TTS/TTSDebugView.swift`，不向 `LlamaBridge` 加 TTS 逻辑。
- 隐藏 Debug 页先只做“选择模型目录 → 文本 → `generateToFile` → WAV → AVFoundation 播放 → 时间/错误日志”。
- 真机首测只选 0.6B 4-bit 模型。公开 README 标注该模型目录约 1.7 GB；GGUF 与 TTS 同时驻留很可能超过部分 iPhone 的 App 内存上限。应统一串行化加载，TTS smoke test 时先卸载 GGUF，并调用 Qwen3TTS 的 `clearCache()`。
- Voice Clone 在基础 TTS 通过后再测：包已公开 speaker embedding、reference audio codes/ICL 和 streaming API，但必须在目标 iPhone 上验证质量、峰值内存、首包延迟和是否真正输出分块 PCM。

## 当前阻塞问题

1. 没有用户 Fork 的可写 GitHub remote 或授权，无法 push 并触发真正的 macOS Runner。
2. Windows 无 Xcode、iOS SDK 和 Metal iPhone runtime，无法本机执行 `xcodebuild` 或真机 smoke test。
3. 未知目标 iPhone 型号、内存和 iOS 版本，不能判断适合的 GGUF/TTS 量化。
4. 主 App 与 Keyboard Extension 使用上游开发团队和 App Group 配置；unsigned build 通常可跳过签名，但 Sideloadly 对 Extension/App Group 的重签名结果仍须实际验证。若失败，先用 Sideloadly 的 Remove Extensions 验证主 App，再决定是否在工程中隐藏 Keyboard target。

## 下一阶段建议

1. 用户先按 `WINDOWS_SETUP.md` 创建自己的 Fork，推送本轮文件并手动运行 workflow。
2. 若失败，下载日志 Artifact 后只修复构建错误，直到 unsigned device build 通过。
3. 用 Sideloadly 在目标 iPhone 上验证主 App、Files 导入、Hugging Face 下载、Metal、流式生成与日志。
4. 基线稳定后再实现 Character 系统；完成并真机回归后，另起阶段接入 Qwen3-TTS smoke test。
