# CoreGate

> 骁龙 8 Gen 5 专用的 Android 锁核 / 限频内核门控模块（Magisk / KernelSU / APatch 通用）。

核心思路只有一句话：**把日常用不到的高频大核关掉，需要性能时立刻放开。**
所有改动都发生在运行时 sysfs 上，**不写任何系统分区，重启即完全还原，零残留。**

- **只适配骁龙 8 Gen 5 机型。** 其他处理器请使用 [CoreGate Pro](https://github.com/zimky180/CoreGate-Pro)。
- 配套管理 App：[CoreGate-App](https://github.com/zimky180/CoreGate-App)（开源，含正式版与 debug APK）。
- 最新版本：**v2.4.2**，发布说明见 [RELEASE-NOTES.md](RELEASE-NOTES.md)，历史见 [Releases](../../releases)。

---

## 它解决什么问题

旗舰 SoC 的调度器倾向于「多开核换流畅」，代价是待机功耗与发热。
CoreGate 反过来做：**平时只保留必要核心，只在真正需要时把核心放出来。**

| 场景 | CoreGate 的行为 |
|---|---|
| 日常使用（前台是普通应用） | 只封锁最高频的那一个（或你设定的 N 个）大核 |
| 打开游戏（命中 `packages.txt`） | 立即恢复全部核心，恢复硬件上限频率 |
| 开始录屏 / 打开相机 | 自动恢复全部核心（`capture_boost` 开启时） |
| 息屏 | 自动锁核 |
| 亮屏 | 自动恢复 |
| 充电 | 默认仍然锁核（可用 `no_lock_charging` 关掉这个保守设定） |
| 温度超过阈值 | 触发高温锁核或高温解封（二选一，阈值可调） |
| 想彻底停手 | 一键恢复原始状态 |

**关闭 App 后模块照常运行，卸载 App 也不影响锁核。** 逻辑全在模块里，App 只是遥控器。

---

## 安装

### 要求

- 设备为骁龙 8 Gen 5 机型（其他处理器请用 Pro 版，本版不适用）。
- 已刷入 **Magisk / KernelSU / APatch** 任一，并能正常获取 root。
- Android 13（API 33）及以上。

### 步骤

1. 从 [Releases](../../releases) 下载 `CoreGate-v2.4.2.zip`。
2. 在 KernelSU / Magisk / APatch 管理器中「从本地安装」该 zip。
3. 重启设备。
4. 打开 [CoreGate-App](https://github.com/zimky180/CoreGate-App) 进行配置。

> **首次安装是「全关」状态。** 安装脚本只做初始化，不会自动开始锁核；必须进 App 打开 `enabled` 并选择要封锁的核心。这是刻意设计——先让你确认设备拓扑被正确识别，再开始动手。

安装过程中脚本会打印检测到的核心拓扑与建议封锁的高频大核，可以对照确认。

### 安装脚本做了什么

- 清理旧版残留：旧 `daemon.pid`、旧日志、`state`、`crash_flag`、`corectl.state`、`log/`。
- 解压模块文件（排除 `META-INF`），按 755 / 644 设置权限，`service.sh`、`uninstall.sh`、`action.sh`、`bin/coregated` 单独赋 755。
- 首次安装把 `config.example.json` 复制为 `/data/adb/CoreGate/config.json`，**不覆盖已有配置**。
- 迁移旧版 `game_packages` 到 `packages.txt`；没有则写入内置默认游戏列表。
- 写入默认 `capture.txt`（录屏 / 相机包名）。
- 执行 `migrate-config.sh`，清理已删除功能在旧配置里留下的字段（如 `freeze_grp_ai` / `voice` / `games` / `themes` / `search`），并留 `config.json.pre-v230.bak` 备份。
- 检测核心拓扑，打印高频大核与建议。

---

## 使用

装好后基本不需要碰命令行。日常操作全部在 App 里：

- **锁核运行状态**：当前封锁了哪些核心、当前前台包名、模块是否存活。
- **封锁核心**：选择要封锁的核心，附带「建议再封锁一个」的组合建议（会解释流畅度与功耗的取舍）。
- **策略**：录屏 / 相机自动恢复、息屏自动锁核、充电时是否锁核、温度策略。
- **日常限频**：小核 / 大核 / GPU 三档限频，预设档位下拉，GPU 另有功耗档位。
- **调试设置**：轮询间隔、配置项直改、状态导出。

### 没有安装 App 时

KernelSU 模块页点「执行」，或直接命令行：

```sh
# 查看硬件与当前状态
su -c '/data/adb/modules/CoreGate/service.sh --hardware-status'

# 手动锁一次 / 恢复
su -c '/data/adb/modules/CoreGate/service.sh --lock-once'
su -c '/data/adb/modules/CoreGate/service.sh --unlock'

# 冻结状态报告
su -c '/data/adb/modules/CoreGate/service.sh --freeze-status'
```

---

## 配置

配置文件：`/data/adb/CoreGate/config.json`
游戏名单：`/data/adb/CoreGate/packages.txt`（一行一个包名）
录屏 / 相机名单：`/data/adb/CoreGate/capture.txt`

完整字段见 [`config.example.json`](config.example.json)。

### 主要字段

| 字段 | 说明 | 默认 |
|---|---|---|
| `enabled` | 模块总开关 | `false` |
| `lock_cores` | 要封锁的核心，`auto` 为自动选最高频大核 | `"auto"` |
| `auto_lock_count` | 自动模式封锁几个核（1~4） | `1` |
| `disable_core_ctl` | 是否一并接管核心控制 | — |
| `no_lock_charging` | 打开后充电时不锁核 | 关（充电仍锁） |
| `poll_interval` | 主循环间隔秒数（5~600，非法值回退 30） | `30` |
| `limit_freq` | 是否启用限频 | `false` |
| `capture_boost` | 录屏 / 相机自动恢复全部核心 | `false` |
| `freeze_grp_*` | 冻结分组开关 | 全关 |
| `temperature_enabled` | 温度策略总开关 | — |
| `temperature_mode` | `lock`（高温锁核）/ `unlock`（高温解封） | `"lock"` |
| `temperature_threshold` | 温度阈值 ℃，可调 35~60 | `40` |
| `cap_little_mhz` / `cap_big_mhz` | 小核 / 大核限频目标 MHz | — |
| `cap_gpu_mhz` / `cap_gpu_pwrlevel` | GPU 限频目标 MHz 或 pwrlevel | — |

> `temperature_threshold` 读的是 **CPU / SoC 传感器温度**，不是机身表面温度。表面 35℃ 时传感器常有 45~50℃。

### 改配置的两种方式

1. **推荐**：App 内改，改完即生效。
2. 手改 `config.json` 后重启模块或等待下一轮轮询。

字段必须**全量保留**：`service.sh` 缺字段时会静默回退默认值，不要手动删行。

---

## 限频说明（本版）

本版限频是**固定档位**实现，与 Pro 版的百分比 + 自适应机制不同：

- 簇目录固定为 `policy0`（小核）与 `policy6`（大核）。
- 目标频率是固定 MHz 值，非法档位会被拒。
- 线性写 sysfs，不做动态 cluster 枚举，也不做自适应调节。

骁龙 8 Gen 5 参考档位（各机实际档位以 `scaling_available_frequencies` 为准）：

| 集群 | 硬件上限 | 档位数 |
|---|---|---|
| 小核 `policy0` | 3321600 kHz | 23 档（不等比） |
| 大核 `policy6` | 3801600 kHz | 21 档（不等比） |
| GPU（KGSL） | 1225 → 195 MHz | 17 档（pwrlevel 0~16） |

GPU 写节点的两个坑，已在本版处理：
1. KGSL 需要 `+800000` 对齐，否则内核会对齐掉你的值。
2. 写完必须 `chmod 444` 锁住节点，否则会被系统改回去。

关闭限频时，模块会把各簇 `scaling_max_freq` **精准还原到开限频前的快照**（`freq_snapshot`），而不是还原成 `cpuinfo_max_freq` —— 后者在多档位机型上会还原错。

---

## 文件结构

```
CoreGate/
├── module.prop           模块元信息
├── customize.sh          安装脚本
├── service.sh            主守护进程入口（加载各 lib、跑主循环、处理命令行入口）
├── uninstall.sh          卸载清理（恢复原始状态）
├── action.sh             KernelSU 模块页「执行」按钮
├── migrate-config.sh     旧配置迁移
├── sepolicy.rule         SELinux 规则
├── update.json           模块内检查更新用
├── config.example.json   配置模板
├── packages.txt          游戏包名名单
├── capture.txt           录屏 / 相机包名名单
├── bin/coregated         守护进程二进制
└── lib/                  各功能实现
```

`service.sh` 启动时会逐一校验依赖文件，缺任何一个直接退出。

### 运行时文件

| 路径 | 用途 |
|---|---|
| `/data/adb/CoreGate/config.json` | 配置 |
| `/data/adb/CoreGate/packages.txt` | 游戏名单 |
| `/data/adb/CoreGate/capture.txt` | 录屏相机名单 |
| `/data/adb/CoreGate/freq_snapshot` | 限频前的频率快照 |
| `/data/adb/CoreGate/state` | 上次前台包名 |
| `/data/adb/CoreGate/daemon.pid` | 守护进程 pid |
| 模块目录 `log/coregate.log` | 运行日志（不可写时回落 `/data/adb/CoreGate/log`） |

日志超过 262144 B 自动截断，保留最后 500 行。

---

## 安全与可逆性

这是本模块最需要说清楚的部分。

**全程只改运行时 sysfs，不写任何系统分区，重启即完全还原。**

- 配置存在 `/data/adb/CoreGate/`（用户数据区），不在系统分区。
- 卸载模块会执行 `uninstall.sh`，恢复核心在线状态与频率上限。
- `cpu0` **永不下线**，避免把自己锁死。
- 逐核下锁之间 `sleep 1`，不做并发风暴。

### 刷入翻车了怎么救（保命三条）

1. 删除 `/data/adb/modules/CoreGate/` 与 `/data/adb/CoreGate/`，重启即恢复。
2. 在模块目录 `touch disable` 做空载验证，确认没问题再放开。
3. 进 Recovery 删掉模块目录，100% 有效。

---

## 常见问题

**Q：装完没反应？**
首次安装默认全关，需要在 App 里打开 `enabled` 并选择核心。模块页「执行」可看到状态。

**Q：App 关了还生效吗？**
生效。锁核、限频、游戏检测、温度策略全在 `service.sh` 里跑，App 只是配置界面。

**Q：会耗电吗？**
主循环默认 30 秒一轮，主要开销是读 sysfs 和一次 `dumpsys`。轮询间隔可调大到 600 秒。

**Q：前台包名显示空 / `-`？**
ColorOS 系 `dumpsys` 有时取不到焦点窗口，属于已知现象，不影响游戏名单匹配之外的逻辑。

**Q：想换处理器平台？**
本版只适配骁龙 8 Gen 5。其他处理器请用 [CoreGate Pro](https://github.com/zimky180/CoreGate-Pro)，那版是动态枚举 cluster + 百分比限频，适配面广得多。

**Q：怎么回退到未限频状态？**
App 内关闭限频即可精准还原（用 `freq_snapshot` 快照）。彻底恢复就卸载模块并重启。

---

## 相关仓库

| 仓库 | 说明 |
|---|---|
| **CoreGate**（本仓库） | 骁龙 8 Gen 5 专用模块 |
| [CoreGate-Pro](https://github.com/zimky180/CoreGate-Pro) | 全机型适配版，锁核与限频独立重写 |
| [CoreGate-App](https://github.com/zimky180/CoreGate-App) | 配套 Android 管理 App（开源） |

## 许可

MIT，见 [LICENSE](LICENSE)。

作者：zimky
