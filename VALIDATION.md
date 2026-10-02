# 第一里程碑验证记录

验证日期：2026-10-03  
环境：Apple Silicon macOS 26.5.2；Apple Swift 6.3.3；Command Line Tools（无完整 Xcode）。

## 技术探针

运行命令：

```sh
swift run maimemo-ax-probe --dump
```

已观察到一次真实结果：

- `appFound=true`
- `trusted=true`
- `nodes=102`
- 当前候选词：`claim`
- 当前墨墨 bundle id：`com.maimemo.ios.momo`

这证明本机当前授权主体能够以只读方式找到墨墨并读取辅助功能树。候选树还返回了 `morelines`、`phraseannotationall`、`leftarrow` 等辅助功能描述，侧栏会把它们限制在调试区域，不把整棵树展示给用户。

## 构建

已通过：

```sh
swift build -c debug
```

构建目标包括：

- `MaimemoAXCore`：共享只读 AX 读取层；
- `maimemo-ax-probe`：命令行技术探针；
- `MaimemoCompanion`：SwiftUI／AppKit 蓝色侧栏。

构建初次受沙箱缓存限制，改用项目内缓存并经本地构建授权后通过；源码仍无第三方依赖。

## 待完成的人工 Gate

- [ ] 打开封装后的 `build/Maimemo Companion.app`，确认蓝色侧栏可见。
- [ ] 在系统辅助功能设置中授权该 `.app`，不是只授权终端。
- [ ] 侧栏显示“已连接墨墨”，并展示实际当前词。
- [ ] 在墨墨学习页切换至少两个词，确认侧栏文字自动变化。
- [ ] 确认侧栏停靠在墨墨窗口右侧，窗口移动后可重新跟随。

如果当前 `.app` 没有权限，应用必须保持“需要辅助功能权限”状态并显示授权路径；这属于未验证，不得写成已完成。

## 已知限制

- AX 文本候选排序是第一版启发式：优先角色、显示尺寸、页面上方位置和遍历顺序；墨墨页面结构变化时可能需要调整。
- 只接受单个 ASCII 英文单词，因此不会把完整例句误判为当前词；音标、释义和例句目前只用于未来扩展，不持久化。
- 本机没有完整 Xcode；当前项目通过 Command Line Tools 的 SwiftPM 编译。若系统后续更新导致 Swift 编译器与 SDK 版本再次不匹配，应先修复开发工具链，再判断项目代码。
