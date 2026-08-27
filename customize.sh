#!/system/bin/sh
# ================================================================
# CoreGate 核心门控 · 安装脚本
# ================================================================
SKIPUNZIP=1

ui_print "=============================="
ui_print "  CoreGate 核心门控 安装中"
ui_print "=============================="

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
