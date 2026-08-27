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
for c in $(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | sed 's/.*cpu//'); do
    d="/sys/devices/system/cpu/cpu$c/cpufreq"
    [ -f "$d/cpuinfo_max_freq" ] && echo "$(cat "$d/cpuinfo_max_freq" 2>/dev/null)" > "$d/scaling_max_freq" 2>/dev/null
    [ -f "$d/cpuinfo_min_freq" ] && echo "$(cat "$d/cpuinfo_min_freq" 2>/dev/null)" > "$d/scaling_min_freq" 2>/dev/null
done

ui_print "- 恢复 core_ctl 原始状态..."
if [ -f "$CORE_CTL_BACKUP" ]; then
    while IFS="$(printf '\t')" read -r node val; do
        [ -z "$node" ] && continue
        echo "$val" > "$node" 2>/dev/null
    done < "$CORE_CTL_BACKUP"
fi

ui_print "- 清理数据文件..."
rm -rf "$CONFIG_DIR"

ui_print "✅ 已卸载，全部恢复原始状态（无需重启）"
