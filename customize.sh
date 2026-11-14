#!/system/bin/sh
# ================================================================
# CoreGate 核心门控 · 安装脚本
# ================================================================
SKIPUNZIP=1

ui_print "=============================="
ui_print "  CoreGate 核心门控 安装中"
ui_print "=============================="

# Stop old daemons before copying persistent recovery records.
for _cg_dir in /data/adb/CoreGate /data/adb/modules/CoreGate/data "$MODPATH/data"; do
    [ -f "$_cg_dir/daemon.pid" ] || continue
    oldpid=$(cat "$_cg_dir/daemon.pid" 2>/dev/null)
    case "$oldpid" in ''|*[!0-9]*) : ;; *) kill "$oldpid" 2>/dev/null; sleep 1 ;; esac
done

ui_print "- 解压模块文件..."
unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2 || abort "! 模块解压失败，安装已中止"
for _cg_required in CoreGate.sh service.sh config.example.json migrate-config.sh lib/config.sh lib/hardware.sh lib/freeze.sh lib/cores.sh lib/frequency.sh lib/probe.sh lib/runtime.sh lib/thermal.sh lib/lifecycle.sh lib/commands.sh; do
    [ -s "$MODPATH/$_cg_required" ] || abort "! 模块文件缺失或为空：$_cg_required"
done
unset _cg_required

ui_print "- 设置脚本权限..."
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
# Rust observer is bundled for manual read-only diagnostics.
if [ -f "$MODPATH/bin/coregated" ]; then
    set_perm "$MODPATH/bin/coregated" 0 0 0755
fi

# Persistent data lives inside the module and must survive staged upgrades.
CONFIG_DIR="$MODPATH/data"
mkdir -p "$CONFIG_DIR" || abort "! 无法创建模块数据目录"
chmod 0755 "$CONFIG_DIR"
cg_copy_asset() {
    _cg_src="$1"; _cg_dst="$2"
    [ -f "$_cg_src" ] || return 0
    [ "$_cg_src" = "$_cg_dst" ] && return 0
    if [ -f "$_cg_dst" ] && ! cmp -s "$_cg_src" "$_cg_dst"; then
        # Never silently overwrite conflicting recovery records.
        abort "! 数据冲突：$_cg_dst；保留旧目录，请先核对"
        return 1
    fi
    cp -p "$_cg_src" "$_cg_dst" || { abort "! 迁移失败，保留旧目录"; return 1; }
    cmp -s "$_cg_src" "$_cg_dst" || { abort "! 迁移校验失败，保留旧目录"; return 1; }
}
# Copy installed module data first (MODPATH may be modules_update/CoreGate).
for _cg_from in /data/adb/modules/CoreGate/data /data/adb/CoreGate; do
    [ "$_cg_from" = "$CONFIG_DIR" ] && continue
    for _cg_asset in config.json packages.txt capture.txt freq_snapshot freeze.state corectl.state factory_snapshot; do
        cg_copy_asset "$_cg_from/$_cg_asset" "$CONFIG_DIR/$_cg_asset" || abort "! 资产迁移失败"
    done
done
# Only persistent assets are copied; stale runtime files must not survive.
rm -f "$CONFIG_DIR/daemon.pid" "$CONFIG_DIR/state" "$CONFIG_DIR/crash_flag"
# Every listed asset has been copied and verified before removing legacy data.
[ ! -d /data/adb/CoreGate ] || rm -rf /data/adb/CoreGate

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

# Remove the resident game assistant from upgraded lists too.
sed -i '/^[[:space:]]*com\.oplus\.games[[:space:]]*$/d' "$CONFIG_DIR/packages.txt"

# 录屏 / 相机包名列表（独立纯文本，每行一个包名，升级不覆盖）
if [ ! -f "$CONFIG_DIR/capture.txt" ]; then
    ui_print "- 写入默认录屏/相机列表..."
    cp -f "$MODPATH/capture.txt" "$CONFIG_DIR/capture.txt"
    chmod 0644 "$CONFIG_DIR/capture.txt"
fi

# 补齐新增厂商策略包名；只追加缺失项，保留自定义内容与原有顺序。
for capture_pkg in com.miui.screenrecorder com.hihonor.camera com.hihonor.screenrecorder com.vivo.smartshot; do
    if ! grep -qxF "$capture_pkg" "$CONFIG_DIR/capture.txt" 2>/dev/null; then
        printf '
%s
' "$capture_pkg" >> "$CONFIG_DIR/capture.txt"
    fi
done
chmod 0644 "$CONFIG_DIR/capture.txt"

# 升级时按当前字段模板迁移；保留有效设置，不在开机时重置配置。
if [ -f "$MODPATH/migrate-config.sh" ]; then
    . "$MODPATH/migrate-config.sh"
    if cg_migrate_config "$CONFIG_DIR/config.json" "$MODPATH/config.example.json"; then
        ui_print "- 配置迁移完成：保留有效设置并清理旧字段"
    else
        ui_print "! 配置迁移未完成，保留原配置"
    fi
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
ui_print "  重启后打开「核心门控」App 查看与调整全部设置"
ui_print "  未装 App 时可在 KernelSU 模块页点「执行」查看状态"
ui_print "  安装「核心门控」App 后在 App 内添加游戏包名"
ui_print "  不安装 App 也能正常锁核（使用默认配置）"