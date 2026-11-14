#!/system/bin/sh
# ================================================================
# CoreGate 核心门控 · service.sh
# ----------------------------------------------------------------
# 原理：
#   日常使用 -> 通过 /sys/devices/system/cpu/cpuN/online 封锁高频大核
#              （默认自动检测最高频簇，如骁龙 8 Gen 5 的 2 颗 3.8GHz 超大核）
#   打开游戏 -> 检测到前台包名命中「游戏列表」时，恢复全部核心
#   录屏/拍照 -> 检测到前台包名命中「录屏/相机清单」时，恢复全部核心
#   离开游戏/录屏/相机 -> 重新封锁
# ----------------------------------------------------------------
# 配置：/data/adb/modules/CoreGate/data/config.json（由 App 写入，本脚本只读执行）
# 日志：/data/adb/modules/CoreGate/log/coregate.log（模块本体目录，卸载随模块一起清除）
# 状态：/data/adb/modules/CoreGate/data/state（供 App 展示）
# ================================================================

MODDIR=${0%/*}

# All runtime libraries must be present before initialization.
for _cg_lib in config hardware freeze cores frequency probe runtime thermal lifecycle commands; do
    [ -r "$MODDIR/lib/$_cg_lib.sh" ] || {
        echo "CoreGate: missing library $_cg_lib.sh" >&2
        exit 1
    }
done
unset _cg_lib
MODULE_ID=$(basename "$MODDIR")
CONFIG_DIR="$MODDIR/data"
CONFIG_FILE="$CONFIG_DIR/config.json"
PACKAGES_FILE="$CONFIG_DIR/packages.txt"
CAPTURE_FILE="$CONFIG_DIR/capture.txt"
# 日志统一放模块本体目录下的 log 子目录；模块目录不可写时回退到配置目录
if [ -d "$MODDIR" ] && [ -w "$MODDIR" ]; then
    LOG_DIR="$MODDIR/log"
else
    LOG_DIR="$CONFIG_DIR/log"
fi
LOG_FILE="$LOG_DIR/coregate.log"
STATE_FILE="$CONFIG_DIR/state"
PID_FILE="$CONFIG_DIR/daemon.pid"
CORE_CTL_BACKUP="$CONFIG_DIR/corectl.state"
# 手动离线的核心清单（一行一个 cpu 编号）
# 为什么需要它：App 点击单个核心下线，如果只写 sysfs，
# 守护进程下一轮 do_lock / do_unlock 会按 LOCK_LIST 直接覆盖掉用户的操作。
# 所以必须把「用户手动关掉的核」持久化，让 do_lock 主动维持、do_unlock 临时恢复。
MANUAL_FILE="$CONFIG_DIR/manual_off"
# ==== v2.5.6 新增：手动恢复标记 ====
# App 点「恢复全部核心」会写入本文件（内容是时间戳）。
# 守护进程看到它就承认「用户此刻要核心在线」，不再自动 do_lock 把核锁回去，
# 直到用户再次手动封锁（lock_once / --core-off）删除本文件为止。
# 这样「关掉轮询开关」与「手动解锁」两条语义彻底分开：
#   enabled=false → 守护进程不巡检、不自动解锁（固态模式继续锁核）
#   UNLOCK_HOLD   → 用户手动要求在线，守护进程尊重
UNLOCK_HOLD="$CONFIG_DIR/unlock_hold"

# 录屏 / 相机内置默认包名（capture.txt 不存在或为空时兜底）
# 这类应用需要全部核心在线才能流畅编码（录屏）或成片（相机）
CAPTURE_DEFAULT="com.oplus.screenrecorder
com.coloros.screenrecorder
com.oneplus.screenrecord
com.android.systemui.screenrecord
com.oplus.camera
com.oneplus.camera
com.coloros.camera
com.android.camera
com.miui.screenrecorder
com.hihonor.camera
com.hihonor.screenrecorder
com.vivo.smartshot"

mkdir -p "$LOG_DIR" 2>/dev/null

# ---------------- 日志（必须先于任何调用定义） ----------------
# v2.5.0 修 Bug#4：日志目录可能在运行中被清掉（模块重装/手动清理/目录权限变化），
# 单靠启动时那一次 mkdir 不够。这里每次写日志前检查，缺失就补建，
# 补建失败则回退到配置目录，保证「日志读不到」不再发生。
log() {
    [ -d "$LOG_DIR" ] || {
        mkdir -p "$LOG_DIR" 2>/dev/null
        [ -d "$LOG_DIR" ] || {
            LOG_DIR="$CONFIG_DIR/log"
            mkdir -p "$LOG_DIR" 2>/dev/null
            LOG_FILE="$LOG_DIR/coregate.log"
        }
    }
    echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null
    sz=$(wc -c < "$LOG_FILE" 2>/dev/null)
    if [ -n "$sz" ] && [ "$sz" -gt 262144 ]; then
        tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null
    fi
}
# 兼容旧版本：把散落在多处旧路径的历史日志并入新日志文件后清理
# 覆盖：/data/adb/modules/CoreGate/data/coregate.log、模块根目录 coregate.log、模块根目录 log/（旧实现）、旧版其它命名
migrate_old_log() {
    for old_log in \
        "$CONFIG_DIR/coregate.log" \
        "$MODDIR/coregate.log" \
        "$CONFIG_DIR/service.log" \
        "$MODDIR/service.log"; do
        [ "$old_log" = "$LOG_FILE" ] && continue
        [ -f "$old_log" ] || continue
        {
            echo "[$(date '+%m-%d %H:%M:%S')] —— 以下为迁移前的历史日志（$old_log）——"
            cat "$old_log" 2>/dev/null
        } >> "$LOG_FILE" 2>/dev/null
        rm -f "$old_log" 2>/dev/null
    done
    # 清理模块根目录残留的旧 .tmp 截断临时文件
    rm -f "$MODDIR/coregate.log.tmp" "$CONFIG_DIR/coregate.log.tmp" 2>/dev/null
}

mkdir -p "$CONFIG_DIR"
migrate_old_log
# 配置缺失时用模块自带默认配置兜底（防止 App 清理后无游戏列表导致只锁不解）
if [ ! -f "$CONFIG_FILE" ] && [ -f "$MODDIR/config.example.json" ]; then
    cp -f "$MODDIR/config.example.json" "$CONFIG_FILE" 2>/dev/null
    chmod 0644 "$CONFIG_FILE" 2>/dev/null
fi
# 包名列表缺失时兜底：优先从旧 config.json 迁移，否则用模块自带默认列表
if [ ! -f "$PACKAGES_FILE" ]; then
    if [ -f "$CONFIG_FILE" ] && grep -q '"game_packages"' "$CONFIG_FILE" 2>/dev/null; then
        # 旧版迁移：从 config.json 的 game_packages 数组提取包名
        sed -n '/"game_packages"/,/]/p' "$CONFIG_FILE" 2>/dev/null \
            | grep -oE '"[^"]+"' | tr -d '"' | grep -v '^game_packages$' > "$PACKAGES_FILE"
    fi
    if [ ! -s "$PACKAGES_FILE" ] && [ -f "$MODDIR/packages.txt" ]; then
        cp -f "$MODDIR/packages.txt" "$PACKAGES_FILE" 2>/dev/null
    fi
    chmod 0644 "$PACKAGES_FILE" 2>/dev/null
fi
# 保留旧版 game_packages 字段：按行截断 JSON 会丢失后续设置或破坏单行配置。

. "$MODDIR/lib/config.sh"
. "$MODDIR/lib/hardware.sh"
. "$MODDIR/lib/freeze.sh"
. "$MODDIR/lib/cores.sh"
. "$MODDIR/lib/frequency.sh"
. "$MODDIR/lib/probe.sh"
. "$MODDIR/lib/runtime.sh"
. "$MODDIR/lib/thermal.sh"
. "$MODDIR/lib/lifecycle.sh"
. "$MODDIR/lib/commands.sh"