# Maimemo Companion

与墨墨并排运行的 macOS 伴学侧栏。当前已加入按词生成记忆卡、本地反馈和记法版本。

## 最短运行方式

先确认 `/Applications/Maimemo.app` 已打开，然后在项目根目录执行：

```sh
./scripts/build-app.sh
open "build/Maimemo Companion.app"
```

首次运行若显示“需要辅助功能权限”：

1. 点击侧栏里的“请求授权”或“打开设置”。
2. 在“系统设置 → 隐私与安全性 → 辅助功能”中打开 `Maimemo Companion`。
3. 重新启动侧栏应用。

也可以解压 `Maimemo-Companion-0.2.0.zip` 后直接打开应用；重新构建时请保留应用所在路径，便于 macOS 继续识别已有辅助功能授权。

命令行只读探针：

```sh
./scripts/run-probe.sh --dump
./scripts/run-probe.sh --watch --dump
```

探针会打印墨墨是否运行、当前进程是否有辅助功能权限、读取节点数、最佳单词候选及少量调试候选。它不点击、不写入墨墨、不读剪贴板、不截图。

## 运行边界

墨墨当前词仍通过 macOS 辅助功能只读获取；无需墨墨 API。记忆卡由用户主动点击生成。模型尚无预置地址或密钥：在侧栏“接入模型”中填写 OpenAI 兼容的完整聊天补全接口地址、模型名称和 API Key。地址与模型名称保存在本机偏好设置，Key 只保存在 macOS 钥匙串；仓库不包含任何凭证。点击生成时，当前词和你填写的卡点会发送到该模型接口。

已经生成的卡片、当前义项的反馈和记法版本存在本机 `~/Library/Application Support/MaimemoCompanion/memory.json`，重新遇到同词时立即显示。当前不接墨墨开放 API、不做 OCR、图像生成或 Codex 插件。完整产品目标与路线见 [PROJECT_BRIEF.md](./PROJECT_BRIEF.md)。

模型没有配置时，实时跟词照常运行，界面会明确显示“模型尚未配置”，不会编造 AI 结果。

记忆模块的本地检查：

```sh
swift run word-memory-check
```

## 本地验证

逐项验证结果见 [VALIDATION.md](./VALIDATION.md)。
