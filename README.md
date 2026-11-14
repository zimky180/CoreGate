# CoreGate · 核心门控模块

**v2.7.1 / 271** · 作者 zimky

日常锁核与限频，游戏自动恢复；支持冻结管理、电池温度策略与游戏保持锁核。模块独立运行，App 用于配置和查看状态。

- [模块下载](https://github.com/zimky180/CoreGate/releases/tag/v2.7.1)
- [配套原生 App 与完整工程](https://github.com/zimky180/CoreGate-App)
- [累计更新说明](RELEASE-NOTES.md)

## 默认行为与兼容性

- 首次安装只锁最高频的一个大核，cpu0 不下线；限频、温度及其他可选策略默认关闭。
- 重启/升级保留已保存设置。当前样例配置的日常轮询为 10 秒、游戏轮询为 30 秒；历史版本默认值不同，以当前配置为准。
- 温度策略使用电池温度，默认阈值 40℃，可设 35～60℃。
- 需要 Root；App 最低 Android 13。硬件驱动、系统限制及其他性能工具可能影响实际锁核和频率行为。
- 限频恢复优先使用首次快照；快照可能记录其他工具已经限制的频率。本版不含逐档试写能力。

## 安装与恢复

1. 从 Releases 下载模块 ZIP，在模块管理器安装并按提示重启。
2. 从 App 发布页下载 APK 安装。
3. 正常升级保留用户配置。模块不需要 App 常驻；App 提供配置、状态和操作入口。
4. 出现异常：管理器禁用模块，或创建 `/data/adb/modules/CoreGate/disable` 后重启。
5. 无法启动：Recovery 删除 `/data/adb/modules/CoreGate`；彻底重置时再删除 `/data/adb/CoreGate` 后重启。

运行时修改 sysfs，不写系统分区。禁用/卸载并重启可撤销运行时修改。

## 本次更新（相对 v2.6.4）

- CPU 限频目标对齐实际档位，避免因读回差异每轮重复写入。
- GPU 已达目标时跳过强化写入，移除 sysfs 写入后的全盘 sync。
- 发布实际包名轮询与息屏状态记录，支持配套 App 扫描详情。
- 补充 HyperOS、MagicOS、OriginOS 录屏与相机包名，升级仅追加缺失项。
- 配套 App 新增进程管理、扫描详情，优化主题、文字与音乐动效。

完整累计更新请见 [v2.7.1 Release](https://github.com/zimky180/CoreGate-App/releases/tag/v2.7.1) 与 [RELEASE-NOTES.md](RELEASE-NOTES.md)。

## 完整源码与打包

`CoreGate.sh` 为控制入口，`lib/` 为同进程加载的 Shell 库，`daemon/` 包含 Rust 观察程序完整源码，`bin/coregated` 为预编译程序，`tools/` 为打包工具。Rust 部分尚处迁移第一阶段。

```sh
python3 tools/package_module.py --source . --output out
```

发布 ZIP 保留模块运行文件与源码注释；Rust 源码、工具等开发文件在本仓库完整提供。更多结构说明见 [daemon/README.md](daemon/README.md) 和 [tools/README.md](tools/README.md)。

## 许可与贡献

项目许可见 [LICENSE](LICENSE)，冻结相关上游说明见 [FREEZE-UPSTREAM.txt](FREEZE-UPSTREAM.txt)。App 完整第三方声明见 [CoreGate-App](https://github.com/zimky180/CoreGate-App)。感谢 App 内列出的全部 13 位贡献者。

更新日期：2026-11-14。
