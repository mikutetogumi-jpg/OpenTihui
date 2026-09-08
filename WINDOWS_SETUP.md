# Windows → GitHub → iPhone 部署说明

本项目的 iOS 编译由 GitHub Actions 的 macOS Runner 完成。Windows 不需要、也不能安装 Xcode。

## 1. 准备账号和软件

1. 注册一个 GitHub 账号。
2. 安装 [GitHub Desktop](https://desktop.github.com/)。这是推荐方式，不要求会 Git 命令。
3. 从 [Sideloadly 官网](https://sideloadly.io/)安装 Windows 版 Sideloadly。
4. 按 Sideloadly 官网提示安装 Apple 官网提供的网页版 iTunes 与 iCloud，不要使用 Microsoft Store 版本。
5. 准备一根能传输数据的 USB 线和一个 Apple ID。仓库与 GitHub Actions 中不要保存 Apple ID 或密码。

## 2. 在 GitHub 创建自己的 Fork

1. 登录 GitHub，打开 <https://github.com/cyyself/OpenTihui>。
2. 点击右上角 **Fork**。
3. 保留默认设置，点击 **Create fork**。
4. 进入自己的 Fork 后，确认地址形如 `https://github.com/你的用户名/OpenTihui`。

## 3. 用 GitHub Desktop 下载项目

1. 在自己的 Fork 页面点击 **Code** → **Open with GitHub Desktop**。
2. 选择一个容易找到、路径较短的位置，例如 `C:\Projects\OpenTihui`。
3. 克隆完成后，在 GitHub Desktop 中点击 **Repository** → **Open in Command Prompt**，只执行一次：

   ```powershell
   git config core.longpaths true
   git submodule update --init --depth 1 llama.cpp
   ```

   llama.cpp 含有很深的文件路径；`core.longpaths` 可避免 Windows 的“Filename too long”错误。

## 4. 用 Codex 修改项目

1. 在 Codex 中打开刚才的 `OpenTihui` 文件夹。
2. 描述需要的改动，并要求 Codex在完成后列出修改文件和验证结果。
3. 不要把 Apple ID、密码、证书、Provisioning Profile 或 API Key 粘贴到项目文件。

## 5. 提交并推送

1. 回到 GitHub Desktop。
2. 左侧检查变更文件，确认没有模型文件、证书或密码。
3. 在左下角 **Summary** 输入简短说明，例如 `ci: add iOS unsigned build`。
4. 点击 **Commit to master**（或 **Commit to main**）。
5. 点击顶部 **Push origin**。

## 6. 运行 GitHub Actions

1. 打开自己的 GitHub Fork。
2. 点击 **Actions**。
3. 首次使用时点击 **I understand my workflows, go ahead and enable them**。
4. 左侧选择 **iOS unsigned build**。
5. 点击 **Run workflow** → **Run workflow**。
6. 等待任务完成。首次需要编译 llama.cpp，耗时会明显更长。

绿色对勾表示构建成功。红色叉号表示失败；打开失败步骤，在页面底部下载 `openTihui-build-logs-*`，将日志交给 Codex 排查。

## 7. 下载构建产物

1. 打开完成的 Actions 运行记录。
2. 在页面底部 **Artifacts** 下载 `openTihui-unsigned-*`。
3. 解压后会得到：

   - `openTihui-unsigned.ipa`：供 Sideloadly 重新签名安装。
   - `openTihui-unsigned-app.zip`：未签名 `.app` 的备份构建产物。

“构建成功”只表示 unsigned App 已成功编译，并不表示已经用你的 Apple ID 签名或安装到 iPhone。

## 8. 使用 Sideloadly 安装

1. 用 USB 连接 iPhone，解锁并在手机上点 **信任此电脑**。
2. 打开 Sideloadly，确认设备已出现在设备下拉框。
3. 将 `openTihui-unsigned.ipa` 拖入 Sideloadly。
4. 输入 Apple ID，点击 **Start**。密码只在 Sideloadly/Apple 登录流程中输入，不要写入仓库。
5. 如果 Keyboard Extension 导致签名或 App Group 报错，可在 Sideloadly 的高级选项中移除 App Extensions 后重试；核心本地聊天位于主 App 中。请保存完整安装日志以便排查。

免费 Apple ID 签名通常需要定期重新安装；以 Sideloadly 当前提示为准。

## 9. iPhone 首次启用

1. iOS 16 及以上：打开 **设置** → **隐私与安全性** → **开发者模式**，开启并按提示重启。
2. 打开 **设置** → **通用** → **VPN 与设备管理**。
3. 选择对应 Apple ID 的开发者 App，点击 **信任**。
4. 返回桌面打开 openTihui。

## 10. 导入和测试 GGUF

1. 在 App 的 Models 页面选择 Files 导入，或使用现有 Hugging Face 下载入口。
2. 首测建议使用适合手机内存的小型 Q4 GGUF，不要从 8B/14B 开始。
3. 加载模型后输入“你好，你是谁？”，观察是否流式输出，并在设置中查看后端和性能统计。

## 11. 出错时提供什么

请一并提供：

- GitHub Actions 运行链接；
- `openTihui-build-logs-*` Artifact；
- Sideloadly 的完整安装日志（先遮盖 Apple ID）；
- iPhone 型号、iOS 版本、GGUF 文件名与量化类型；
- App 内 llama.cpp 日志页中故障前后的内容。

不要只提供“打不开”或“失败”的截图；完整文本日志最有利于定位问题。
