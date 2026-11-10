#!/system/bin/sh
# ================================================================
# 核心门控 卸载脚本
# 目标：卸载后【立即】恢复全部原始状态，无任何残留
#   - 停止模块服务进程（service.sh）
#   - 全部核心上线
#   - 恢复 CPU 频率上限/下限
#   - 恢复 core_ctl 原始值（首次关闭前备份的）
#   - 删除配置/日志/状态/PID 等全部数据文件
# 即使卸载脚本不执行（如手动删目录），重启后 sysfs 也会自动恢复
# ================================================================
MODDIR=${0%/*}
CONFIG_DIR="/data/adb/CoreGate"
PID_FILE="$CONFIG_DIR/daemon.pid"
CORE_CTL_BACKUP="$CONFIG_DIR/corectl.state"

ui_print "- 停止模块服务进程..."
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
    [ -n "$OLD_PID" ] && kill -15 "$OLD_PID" 2>/dev/null
    sleep 1
    [ -n "$OLD_PID" ] && kill -9 "$OLD_PID" 2>/dev/null
fi

ui_print "- 恢复全部 CPU 核心..."
for c in $(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | sed 's/.*cpu//'); do
    echo 1 > "/sys/devices/system/cpu/cpu$c/online" 2>/dev/null
done

ui_print "- 恢复 CPU 频率..."
for d in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$d" ] || continue
    saved=$(awk -F= -v p="$d" '$1==p {v=$2} END{print v}' "$CONFIG_DIR/freq_snapshot" 2>/dev/null)
    if [ -z "$saved" ]; then
        saved=$(cat "$d/scaling_available_frequencies" 2>/dev/null | tr ' ' '\n' | sort -nr | head -1)
        [ -n "$saved" ] || saved=$(cat "$d/cpuinfo_max_freq" 2>/dev/null)
    fi
    case "$saved" in ''|*[!0-9]*) continue;; esac
    echo "$saved" > "$d/scaling_max_freq" 2>/dev/null
done

ui_print "- 恢复 GPU 频率/功耗档位..."
# 注意：service.sh 限频时会把 kgsl 节点 chmod 444 锁定，若此处不解锁，
# 下面的写回会因权限被拒而静默失败 → GPU 永久卡在限频状态。
# 因此必须先 chmod 644 解开锁定，再写回原始上限。
GPU_DIR="/sys/class/kgsl/kgsl-3d0"
if [ -d "$GPU_DIR" ]; then
    for _n in "$GPU_DIR/max_gpuclk" "$GPU_DIR/devfreq/max_freq" "$GPU_DIR/max_pwrlevel"; do
        [ -e "$_n" ] && chmod 644 "$_n" 2>/dev/null
    done
    # 恢复真实最大合法档（本机 1225000000），而非厂商虚标的 cpuinfo 值
    [ -e "$GPU_DIR/max_gpuclk" ] && echo "1225000000" > "$GPU_DIR/max_gpuclk" 2>/dev/null
    [ -e "$GPU_DIR/devfreq/max_freq" ] && echo "1225000000" > "$GPU_DIR/devfreq/max_freq" 2>/dev/null
    # 解限 = 允许 GPU 跑最高性能档 0；min/default 从未被 CoreGate 改动，绝不动它
    [ -e "$GPU_DIR/max_pwrlevel" ] && echo "0" > "$GPU_DIR/max_pwrlevel" 2>/dev/null
fi

ui_print "- 恢复 core_ctl 原始状态..."
if [ -f "$CORE_CTL_BACKUP" ]; then
    while IFS="$(printf '\t')" read -r node val; do
        [ -z "$node" ] && continue
        echo "$val" > "$node" 2>/dev/null
    done < "$CORE_CTL_BACKUP"
fi

# 说明：v2.1.0 起 APK 为【独立应用】（方案 A：不注入系统分区），
#       与模块解耦——模块卸载不影响 App，App 删除也不影响模块。
#       因此这里不再清理任何应用，只需恢复系统状态与数据文件。
ui_print "- 恢复被停用的系统组件..."
# 关键：组件停用记录存在 $CONFIG_DIR/freeze.state 里，而下面会 rm -rf 整个 CONFIG_DIR。
# 若不在这之前把组件逐个 enable 回来，用户卸载模块后这些系统组件会永久处于停用状态，
# 造成「卸载了但功能再也回不来」的严重残留 —— 必须放在删除数据之前。
FREEZE_STATE="$CONFIG_DIR/freeze.state"
# Use the same upstream-derived transport, fallbacks and legacy migration as App commands.
if [ -f "$MODDIR/service.sh" ] && [ -f "$FREEZE_STATE" ]; then
    if ! sh "$MODDIR/service.sh" --freeze-restore; then
        ui_print "  · 组件恢复未完成，保留数据，请在 App 中重试解冻"
        exit 1
    fi
fi
if [ -s "$FREEZE_STATE" ]; then
    # 记录格式：每行「包名<TAB>原始状态」
    # 只恢复原始态为 enabled 的（那才是本模块改过的）；
    # 原始态为 disabled 的是用户自己停用的，卸载时保持原样，不擅自打开。
    TAB="$(printf '\t')"
    while IFS="$TAB" read -r _p _st _mode; do
        [ -z "$_p" ] && continue
        if [ "$_st" = "enabled" ]; then
            if [ "$_mode" = suspend ]; then
                pm unsuspend --user 0 "$_p" >/dev/null 2>&1
            else
                pm enable --user 0 "$_p" >/dev/null 2>&1
            fi
            if [ $? != 0 ]; then
                ui_print "  · 恢复失败 $_p，保留记录，请先在 App 中重试解冻"
                exit 1
            fi
            ui_print "  · 已恢复 $_p"
        else
            ui_print "  · 保持停用 $_p（原本就是您手动停用的）"
        fi
    done < "$FREEZE_STATE"
fi

ui_print "- 清理数据文件..."
rm -rf "$CONFIG_DIR"
rm -rf /data/local/tmp/CoreGate
# 新版日志写在模块本体目录的 log/ 子目录内，卸载时连同旧版残留一并清除
# （模块目录随后会被 KernelSU 移除，这里主动清理确保零残留）
rm -rf "$MODDIR/log" 2>/dev/null
rm -f "$MODDIR/coregate.log" "$MODDIR/coregate.log.tmp" \
      "$MODDIR/coregate.log.old" "$MODDIR/service.log" 2>/dev/null

ui_print "✅ 已卸载，全部恢复原始状态（无需重启）"