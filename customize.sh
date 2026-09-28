#!/system/bin/sh
# ================================================================
# CoreGate 核心门控 · 安装脚本
# ================================================================
SKIPUNZIP=1

ui_print "=============================="
ui_print "  CoreGate 核心门控 安装中"
ui_print "=============================="

# ---------- 安装前清理旧版本残留 ----------
# 目的：不论从哪个旧版本升级/重装，都先彻底清掉历史残留，避免版本间状态错乱。
# 注意：只清【运行时残留/旧日志/旧临时文件】，绝不删除用户配置（config.json / packages.txt），
#       保证「完全可逆 + 升级不丢配置」的模块哲学不被破坏。
ui_print "- 清理旧版本残留..."

# 1) 旧的运行配置目录（历史版本曾把日志/状态留在此处；新版只保留 config.json 与 packages.txt）
if [ -d "/data/adb/CoreGate" ]; then
    # 先停掉可能仍在运行、且指向旧路径的守护进程
    if [ -f "/data/adb/CoreGate/daemon.pid" ]; then
        oldpid=$(cat "/data/adb/CoreGate/daemon.pid" 2>/dev/null)
        case "$oldpid" in
            ''|*[!0-9]*) : ;;
            *) kill "$oldpid" 2>/dev/null; sleep 1 ;;
        esac
    fi
    # 清掉旧日志与旧状态，保留用户配置
    rm -f "/data/adb/CoreGate/coregate.log" \
          "/data/adb/CoreGate/coregate.log.tmp" \
          "/data/adb/CoreGate/service.log" \
          "/data/adb/CoreGate/state" \
          "/data/adb/CoreGate/daemon.pid" \
          "/data/adb/CoreGate/crash_flag" \
          "/data/adb/CoreGate/corectl.state" 2>/dev/null
    rm -f /data/adb/CoreGate/giveup_* 2>/dev/null
    rm -rf "/data/adb/CoreGate/log" 2>/dev/null
fi

# 2) 模块本体目录内可能的旧日志残留（同一次升级时 MODPATH 已就位）
rm -f "$MODPATH/coregate.log" "$MODPATH/coregate.log.tmp" 2>/dev/null
rm -rf "$MODPATH/log" 2>/dev/null

ui_print "- 解压模块文件..."
unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2

ui_print "- 设置脚本权限..."
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755

# 数据目录放模块外：升级模块不覆盖配置
CONFIG_DIR="/data/adb/CoreGate"
mkdir -p "$CONFIG_DIR"
chmod 0755 "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/config.json" ]; then
    ui_print "- 首次安装：写入默认配置..."
    cp -f "$MODPATH/config.example.json" "$CONFIG_DIR/config.json"
    chmod 0644 "$CONFIG_DIR/config.json"
fi

# 游戏包名列表（独立纯文本，每行一个包名，升级不覆盖）
if [ ! -f "$CONFIG_DIR/packages.txt" ]; then
    if [ -f "$CONFIG_DIR/config.json" ] && grep -q '"game_packages"' "$CONFIG_DIR/config.json" 2>/dev/null; then
        ui_print "- 迁移旧版游戏列表..."
        sed -n '/"game_packages"/,/]/p' "$CONFIG_DIR/config.json" 2>/dev/null \
            | grep -oE '"[^"]+"' | tr -d '"' | grep -v '^game_packages$' > "$CONFIG_DIR/packages.txt"
    fi
    if [ ! -s "$CONFIG_DIR/packages.txt" ]; then
        ui_print "- 写入默认游戏列表..."
        cp -f "$MODPATH/packages.txt" "$CONFIG_DIR/packages.txt"
    fi
    chmod 0644 "$CONFIG_DIR/packages.txt"
fi

# 检测核心拓扑（仅提示用）
detect_high_cluster() {
    local maxf=0 c f out=""
    for c in $(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | sed 's/.*cpu//'); do
        f=$(cat "/sys/devices/system/cpu/cpu$c/cpufreq/cpuinfo_max_freq" 2>/dev/null)
        [ -z "$f" ] && continue
        if [ "$f" -gt "$maxf" ]; then
            maxf="$f"; out="$c"
        elif [ "$f" -eq "$maxf" ]; then
            out="$out $c"
        fi
    done
    echo "$out"
}

ui_print "- 检测核心拓扑..."
TOTAL=0
for c in $(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null); do TOTAL=$((TOTAL+1)); done
ui_print "  共 ${TOTAL} 个核心"
TOP=$(detect_high_cluster)
if [ -n "$TOP" ]; then
    ui_print "  高频大核: cpu$(echo $TOP | sed 's/ / cpu/g')"
else
    ui_print "  ⚠️ 未能读取 cpufreq 信息（不影响安装）"
fi

ui_print "✅ 安装完成！"
ui_print "  重启后打开 KernelSU 管理器 → 模块"
ui_print "  进入 CoreGate 的 WebUI 添加游戏包名"