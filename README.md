# Maimemo Companion

第一里程碑：与墨墨并排运行的蓝色只读跟词侧栏。

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

命令行只读探针：

```sh
./scripts/run-probe.sh --dump
./scripts/run-probe.sh --watch --dump
```

探针会打印墨墨是否运行、当前进程是否有辅助功能权限、读取节点数、最佳单词候选及少量调试候选。它不点击、不写入墨墨、不读剪贴板、不截图。

## 运行边界

当前版本不接墨墨 API、账号凭证、OCR、大语言模型、图像生成、Codex 插件或本地词汇历史数据库。完整产品目标、技术证据和后续路线见 [PROJECT_BRIEF.md](./PROJECT_BRIEF.md)。

## 本地验证

逐项验证结果见 [VALIDATION.md](./VALIDATION.md)。
