# CoreGate Rust 迁移：第一阶段

当前已落地 Shell 职责拆分与 Rust 只读观察器源码。Rust 尚未编译、接入启动或部署；现有锁核、限频、冻结、温度决策和退出恢复继续由 Shell 负责。APK 包名、通信入口及配置位置保持兼容。

## Shell 布局

`service.sh` 保留路径、日志和缺失配置初始化，然后按原顺序加载以下库：

| 文件 | 职责 |
| --- | --- |
| lib/config.sh | 原有配置读取和布尔字段写回 |
| lib/hardware.sh | CPU 拓扑、core_ctl 备份恢复、手动核心名单 |
| lib/freeze.sh | 冻结表、组策略、记录与恢复 |
| lib/cores.sh | 核心控制锁、锁核与恢复 |
| lib/frequency.sh | 限频、快照与恢复 |
| lib/probe.sh | 屏幕、前台包名、游戏与充电检测 |
| lib/runtime.sh | 主循环共享初始状态 |
| lib/thermal.sh | 电池温度、滞回与温度策略 |
| lib/lifecycle.sh | 开机等待、安全模式、主循环与退出恢复 |
| lib/commands.sh | APK 使用的一次性命令与默认常驻入口 |

这些库必须用 `.` 在入口进程内加载，不能作为子进程执行，否则共享状态和退出 trap 的语义会改变。安装脚本现有递归权限已覆盖库文件，库只需可读。CI 打包清单已加入 `lib/` 和原先遗漏的 `migrate-config.sh`。

## Rust 观察器

`src/config.rs` 一次读取并解析完整 JSON，保留原始键，另外生成规范化配置。默认值来自模块的 `config.example.json`，当前轮询默认 10 秒。文档损坏、文件缺失或根对象类型错误会明确报告，不静默生成启用策略。字段类型错误回退该字段默认值。未知字段保留在 `raw` 中，源码没有配置写回。

`src/probe.rs` 直接读取 CPU 在线状态、cpufreq 簇、频率上限、电池温度与状态、KGSL GPU 上限。温度单位统一为毫摄氏度，电池原始值乘 100。缺失或不可读节点输出 `null`，不会拿 CPU 热点替代电池温度，也不运行 dumpsys、su 或外部命令。

编译后命令接口设计为：

```text
coregated --once
coregated --watch
coregated --once --config /path/config.json --sys-root /path/fixture/sys
coregated --watch --module-dir /data/adb/modules/CoreGate
```

默认单次输出一行 JSON；`--watch` 每轮重新解析配置，按配置间隔采样。持续观察模式发现模块删除、禁用、remove 标记时退出，等待期间每秒检查一次。正常 TERM/INT 使用进程默认退出行为；观察器没有需要恢复的设备写入。输出只走 stdout，错误走 stderr；不使用 Shell 的 `daemon.pid`、`state`、冻结记录或任何 sysfs 写接口。

当前有效配置仅用于诊断。Rust 的严格 JSON 解析与旧 sed 对损坏/重复键等输入的容错并不完全相同，不能直接当作控制逻辑替换。GPU 档位的设备校验在硬件采集后进行，并保持 Shell 的默认档位语义。观察器尚未实现前台、屏幕和冻结状态采集，也没有接管策略或减少现有 Shell 子进程；本阶段不宣称实际功耗或性能收益。

## 验证与后续迁移

本轮仅进行 Shell 语法检查、拆分内容等价校验、独立配置函数验证和打包依赖检查。Rust 中已准备配置边界与 CPU 列表单元测试，遵守“先别编译”的要求，未运行 cargo test、cargo check 或构建；类型、链接与 Android 运行情况待后续编译验证。

后续顺序：获准构建后锁定 Cargo 依赖，执行 Rust 测试并交叉编译 Android arm64；先在隔离文件树校验输出，再比较真机只读采样；随后让 Shell 消费明确版本的配置/状态协议，保留失败回退；最后才逐步迁移策略和节点执行。切换控制执行前必须覆盖安全模式、游戏恢复、禁用/卸载、TERM 和配置热更新，保持唯一控制进程和现有精确恢复能力。

本阶段不引入 eBPF、LKM、Java daemon，不自动启动 Rust，不生成新 APK 或模块 ZIP。