#!/system/bin/sh
# ================================================================
# CoreGate 核心门控 · service.sh
# ----------------------------------------------------------------
# 原理：
#   日常使用 -> 通过 /sys/devices/system/cpu/cpuN/online 封锁高频大核
#              （默认自动检测最高频簇，如骁龙 8 Gen 5 的 2 颗 3.8GHz 超大核）
#   打开游戏 -> 检测到前台包名命中「游戏列表」时，恢复全部核心
#   离开游戏 -> 重新封锁
# ----------------------------------------------------------------
# 配置：/data/adb/CoreGate/config.json（由 WebUI 写入，本脚本只读执行）
# 日志：/data/adb/modules/CoreGate/log/coregate.log（模块本体目录，卸载随模块一起清除）
# 状态：/data/adb/CoreGate/state（供 WebUI 展示）
# ================================================================

MODDIR=${0%/*}
MODULE_ID=$(basename "$MODDIR")
CONFIG_DIR="/data/adb/CoreGate"
CONFIG_FILE="$CONFIG_DIR/config.json"
PACKAGES_FILE="$CONFIG_DIR/packages.txt"
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

mkdir -p "$LOG_DIR" 2>/dev/null

# ---------------- 日志（必须先于任何调用定义） ----------------
log() {
    echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null
    sz=$(wc -c < "$LOG_FILE" 2>/dev/null)
    if [ -n "$sz" ] && [ "$sz" -gt 262144 ]; then
        tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null
    fi
}
# 兼容旧版本：把散落在多处旧路径的历史日志并入新日志文件后清理
# 覆盖：/data/adb/CoreGate/coregate.log、模块根目录 coregate.log、模块根目录 log/（旧实现）、旧版其它命名
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
echo $$ > "$PID_FILE" 2>/dev/null
migrate_old_log
# 配置缺失时用模块自带默认配置兜底（防止 WebUI 清理后无游戏列表导致只锁不解）
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
# 旧版 config.json 若还带 game_packages 大数组 → 剥离瘦身（包名已迁到 packages.txt），
# 保持 config.json 为小文件，WebUI 可整读解析不截断
if [ -f "$CONFIG_FILE" ] && grep -q '"game_packages"' "$CONFIG_FILE" 2>/dev/null; then
    sed -n '1,/"game_packages"/p' "$CONFIG_FILE" 2>/dev/null | sed '$d' | sed '$s/,$//' > "$CONFIG_FILE.tmp" 2>/dev/null
    echo '}' >> "$CONFIG_FILE.tmp"
    [ -s "$CONFIG_FILE.tmp" ] && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE" && chmod 0644 "$CONFIG_FILE"
    rm -f "$CONFIG_FILE.tmp"
    log "已剥离旧版 game_packages 数组，config.json 已瘦身"
fi

# ---------------- 配置读取（config.json 每字段一行） ----------------
cfg_val() {  # 字符串
    k="$1"; d="$2"
    v=$(sed -n "s/.*\"$k\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$CONFIG_FILE" 2>/dev/null | head -1)
    [ -n "$v" ] && echo "$v" || echo "$d"
}
cfg_bool() {  # 布尔
    k="$1"; d="$2"
    v=$(sed -n "s/.*\"$k\"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p" "$CONFIG_FILE" 2>/dev/null | head -1)
    [ -n "$v" ] && echo "$v" || echo "$d"
}
cfg_int() {  # 数字
    k="$1"; d="$2"
    v=$(sed -n "s/.*\"$k\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$CONFIG_FILE" 2>/dev/null | head -1)
    [ -n "$v" ] && echo "$v" || echo "$d"
}

# ---------------- 核心工具 ----------------
all_cpus() {
    ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | sed 's/.*\/cpu//' | sort -n
}
cpu_online() {  # $1=cpu -> 在线返回0
    [ "$(cat "/sys/devices/system/cpu/cpu$1/online" 2>/dev/null)" = "1" ]
}
set_cpu() {  # $1=cpu $2=0/1
    [ -f "/sys/devices/system/cpu/cpu$1/online" ] || return 1
    echo "$2" > "/sys/devices/system/cpu/cpu$1/online" 2>/dev/null
}
online_count() {
    n=0
    for c in $(all_cpus); do
        cpu_online "$c" && n=$((n+1))
    done
    echo "$n"
}
# 关闭高通的 core_ctl（否则它会把刚离线的核又拉回来）
# 首次关闭前备份各节点原始值（全部节点），卸载时精确还原
disable_core_ctl() {
    first=0
    if [ ! -f "$CORE_CTL_BACKUP" ]; then
        first=1
        : > "$CORE_CTL_BACKUP"
    fi
    for d in /sys/devices/system/cpu/cpu*/core_ctl; do
        [ -f "$d/enable" ] || continue
        if [ "$first" = "1" ]; then
            v=$(cat "$d/enable" 2>/dev/null)
            [ -n "$v" ] && printf '%s\t%s\n' "$d/enable" "$v" >> "$CORE_CTL_BACKUP"
        fi
        echo 0 > "$d/enable" 2>/dev/null
    done
    # 没有可备份节点时，清掉空备份文件
    [ "$first" = "1" ] && [ ! -s "$CORE_CTL_BACKUP" ] && rm -f "$CORE_CTL_BACKUP"
}
restore_core_ctl() {
    [ -f "$CORE_CTL_BACKUP" ] || return 0
    while IFS="$(printf '\t')" read -r node val; do
        [ -z "$node" ] && continue
        echo "$val" > "$node" 2>/dev/null
    done < "$CORE_CTL_BACKUP"
    rm -f "$CORE_CTL_BACKUP"
}
# 自动检测「最高频簇」= 需要封锁的大核（如 8 Gen 5 的 cpu6/cpu7）
# 默认只锁 1 个（最稳，对应 Scene 实测可行的量），可在 WebUI 调 auto_lock_count 或手动指定
detect_high() {
    total=0; cap=0; maxf=0
    for c in $(all_cpus); do
        total=$((total+1))
        f=$(cat "/sys/devices/system/cpu/cpu$c/cpufreq/cpuinfo_max_freq" 2>/dev/null)
        [ -n "$f" ] && [ "$f" -gt "$maxf" ] && maxf="$f"
    done
    case "$AUTO_COUNT" in
        ''|*[!0-9]*) AUTO_COUNT=1;;
    esac
    cap=$AUTO_COUNT; [ "$cap" -lt 1 ] && cap=1; [ "$cap" -gt 4 ] && cap=4
    [ "$maxf" -eq 0 ] && { echo ""; return; }
    for c in $(all_cpus); do
        f=$(cat "/sys/devices/system/cpu/cpu$c/cpufreq/cpuinfo_max_freq" 2>/dev/null)
        [ -n "$f" ] && [ "$f" -eq "$maxf" ] && echo "$c"
    done | sort -nr | head -n "$cap" | tr '\n' ' '
}

# ---------------- 封锁 / 恢复 ----------------
# 逐核渐进封锁。注意：这里【没有】"被系统拉回 N 次就放弃"的机制——
# 被拉回只记录失败，下一轮继续努力封锁，保证用户配置始终真正生效。
LOCK_STATE=""   # 本轮各核封锁结果，仅用于日志
do_lock() {
    LOCK_STATE=""
    [ "$DISABLE_CC" = "true" ] && disable_core_ctl
    for c in $LOCK_LIST; do
        [ "$c" = "0" ] && continue                     # cpu0 永不下线
        if cpu_online "$c"; then
            if set_cpu "$c" 0; then
                LOCK_STATE="${LOCK_STATE}${c}:ok "
                sleep 1   # 逐核渐进：避免同时离线多核造成系统冲击
            else
                LOCK_STATE="${LOCK_STATE}${c}:fail "
                log "封锁 cpu$c 失败（可能被内核/厂商策略拒绝）"
            fi
        fi
    done
}
do_unlock() {
    for c in $LOCK_LIST; do
        [ "$c" = "0" ] && continue
        if ! cpu_online "$c"; then
            set_cpu "$c" 1 && log "恢复 cpu$c"
        fi
    done
}

# ---------------- 日常限频（锁定安全频率上限，进一步省电） ----------------
# 设计取舍：
#   1) 用【绝对频率上限】而非百分比，避免不同核心硬件上限差异导致数学误差；
#   2) 写入值 = 目标MHz*1000 + 800，让内核向下对齐到最近的合法档次；
#   3) 仅当【当前读数偏离目标】才写，避免无意义刷写带来的额外 CPU 唤醒与功耗；
#   4) 不做「连续写 4 次 + chmod 444 锁节点」的对抗式循环——那会与厂商调度持续打架，
#      反而抬高功耗，并破坏系统对节点的合法写入能力（违背 CoreGate 完全可逆哲学）；
#   5) GPU 只压 max_gpuclk / max_pwrlevel / min_pwrlevel / default_pwrlevel 与 devfreq，
#      不锁死节点，靠主循环周期性纠偏即可。
FREQ_CAPPED=0
# 锁定的安全上限（用户不可调）
CAP_LITTLE_MHZ=2266      # policy0（小核簇）上限
CAP_BIG_MHZ=1651         # policy6（大核簇）上限
CAP_GPU_MHZ=500          # GPU 上限
CAP_GPU_PWRLEVEL=13      # GPU 最高功耗档位
GPU_RESTORE_MHZ=1225000000   # 恢复时 GPU 硬件上限
P0_DIR="/sys/devices/system/cpu/cpufreq/policy0"
P6_DIR="/sys/devices/system/cpu/cpufreq/policy6"
GPU_DIR="/sys/class/kgsl/kgsl-3d0"

# 仅当当前值偏离目标才写，减少无意义刷写
freq_write_if_needed() {
    _path="$1"; _target="$2"
    [ -e "$_path" ] || return 1
    _cur=$(cat "$_path" 2>/dev/null)
    [ "$_cur" = "$_target" ] && return 0
    echo "$_target" > "$_path" 2>/dev/null
}

# 对某个 cpu freq policy 目录设置 scaling_max_freq（+800 对齐）
cap_cluster() {
    _dir="$1"; _mhz="$2"
    [ -d "$_dir" ] || return 1
    _want=$(( _mhz * 1000 + 800 ))
    # 不超过该簇硬件上限
    _hw=$(cat "$_dir/cpuinfo_max_freq" 2>/dev/null)
    if [ -n "$_hw" ] && [ "$_want" -gt "$_hw" ]; then _want="$_hw"; fi
    freq_write_if_needed "$_dir/scaling_max_freq" "$_want"
}
restore_cluster() {
    _dir="$1"
    [ -d "$_dir" ] || return 1
    _hw=$(cat "$_dir/cpuinfo_max_freq" 2>/dev/null)
    [ -n "$_hw" ] && freq_write_if_needed "$_dir/scaling_max_freq" "$_hw"
}

apply_freq_cap() {
    [ "$LIMIT_FREQ" = "true" ] || return 0
    cap_cluster "$P0_DIR" "$CAP_LITTLE_MHZ"
    cap_cluster "$P6_DIR" "$CAP_BIG_MHZ"
    # GPU：功耗档位与频率上限
    freq_write_if_needed "$GPU_DIR/max_pwrlevel" "$CAP_GPU_PWRLEVEL"
    freq_write_if_needed "$GPU_DIR/min_pwrlevel" "$CAP_GPU_PWRLEVEL"
    freq_write_if_needed "$GPU_DIR/default_pwrlevel" "$CAP_GPU_PWRLEVEL"
    [ -e "$GPU_DIR/max_gpuclk" ] && freq_write_if_needed "$GPU_DIR/max_gpuclk" "$(( CAP_GPU_MHZ * 1000000 ))"
    [ -e "$GPU_DIR/devfreq/max_freq" ] && freq_write_if_needed "$GPU_DIR/devfreq/max_freq" "$(( CAP_GPU_MHZ * 1000000 ))"
    [ "$FREQ_CAPPED" = "1" ] || log "已启用日常限频：小核≤${CAP_LITTLE_MHZ}MHz 大核≤${CAP_BIG_MHZ}MHz GPU≤${CAP_GPU_MHZ}MHz/档位${CAP_GPU_PWRLEVEL}"
    FREQ_CAPPED=1
}
remove_freq_cap() {
    [ "$FREQ_CAPPED" = "1" ] || return 0
    restore_cluster "$P0_DIR"
    restore_cluster "$P6_DIR"
    if [ -d "$GPU_DIR" ]; then
        hw=$(( GPU_RESTORE_MHZ / 1000000 ))
        [ -e "$GPU_DIR/max_gpuclk" ] && freq_write_if_needed "$GPU_DIR/max_gpuclk" "$GPU_RESTORE_MHZ"
        [ -e "$GPU_DIR/devfreq/max_freq" ] && freq_write_if_needed "$GPU_DIR/devfreq/max_freq" "$GPU_RESTORE_MHZ"
        freq_write_if_needed "$GPU_DIR/max_pwrlevel" "0"
        freq_write_if_needed "$GPU_DIR/min_pwrlevel" "0"
        freq_write_if_needed "$GPU_DIR/default_pwrlevel" "0"
    fi
    FREQ_CAPPED=0
    log "已取消日常限频，恢复硬件上限"
}

# ---------------- 屏幕状态（优先免费 sysfs，失败回退 dumpsys） ----------------
screen_sysfs() {
    for b in /sys/class/backlight/*/bl_power; do
        [ -e "$b" ] || continue
        v=$(cat "$b" 2>/dev/null)
        case "$v" in 0) echo ON; return;; *) echo OFF; return;; esac
    done
    for b in /sys/class/backlight/*/actual_brightness /sys/class/backlight/*/brightness; do
        [ -e "$b" ] || continue
        v=$(cat "$b" 2>/dev/null)
        [ -n "$v" ] && [ "$v" = "0" ] && { echo OFF; return; }
        [ -n "$v" ] && [ "$v" -gt 0 ] 2>/dev/null && { echo ON; return; }
    done
    echo UNKNOWN
}

# ---------------- 前台应用检测（多候选：覆盖全屏游戏/挂屏/焦点） ----------------
fg_pkgs() {
    # 方式1：dumpsys window 多字段（ColorOS 全屏游戏/游戏空间前台更可靠）
    out=$(dumpsys window 2>/dev/null \
        | grep -E 'mCurrentFocus|mFocusedApp|mHoldScreenWindow|mTopFullscreenOpaque|mObscuringWindow|mLastFocusedWindow' \
        | sed -E 's/.* ([a-zA-Z0-9.]+)\/.*/\1/' \
        | grep -E '^[a-zA-Z][a-zA-Z0-9_.]*$' | grep -v '^null$' | sort -u)
    if [ -n "$out" ]; then
        echo "$out"
        return
    fi
    # 方式2：activity 状态
    out=$(dumpsys activity activities 2>/dev/null \
        | grep -m1 -E 'mResumedActivity|topResumedActivity' \
        | grep -oE '[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+' | head -1)
    [ -n "$out" ] && { echo "$out"; return; }
    # 方式3：mCurrentFocus 兜底
    out=$(dumpsys window 2>/dev/null \
        | grep -m1 'mCurrentFocus' \
        | grep -oE '[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+' | head -1)
    echo "$out"
}
is_game() {  # $1=多行候选包名，任一精确命中即游戏
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        case "$pkg" in null) continue;; esac
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            case "$line" in \#*) continue;; esac
            [ "$pkg" = "$line" ] && return 0
        done <<LIST
$GAME_LIST
LIST
    done <<PKGS
$1
PKGS
    return 1
}

# ---------------- 屏幕 / 充电状态 ----------------
is_charging() {
    s=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
    if [ "$s" = "Charging" ] || [ "$s" = "Full" ]; then return 0; fi
    dumpsys battery 2>/dev/null | grep -qE 'AC powered: true|USB powered: true|Wireless powered: true'
}

# ---------------- 主循环 ----------------
LOCK_LIST=""
GAME_LIST=""
LIMIT_FREQ="false"
AUTO_COUNT=1
DISABLE_CC="false"
SAFE_MODE=0
INTERVAL=30

# ---------------- 完全恢复（可逆性保证） ----------------
# 卸载 / 删除 / 禁用时：恢复核心、频率、core_ctl 原始值，不留任何运行残留
restore_all() {
    do_unlock
    remove_freq_cap
    restore_core_ctl
}

TRAP_DONE=0
cleanup_on_exit() {
    [ "$TRAP_DONE" = "1" ] && exit 0
    TRAP_DONE=1
    restore_all
    rm -f "$PID_FILE" "$CONFIG_DIR/crash_flag"
    log "模块服务已退出，全部恢复原始状态"
    exit 0
}
trap cleanup_on_exit TERM INT EXIT

run() {
    state=""; pkg=""; want_lock=""; last_pkg=""; lock_logged=0; ss=""; it2=0; last_ss=""
    prev_unlocked=0; oc_now=""

    # ========== 开机延迟：等系统完全启动再锁核（防止干扰开机导致卡机/崩溃） ==========
    wc=0
    while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$wc" -lt 90 ]; do
        sleep 1
        wc=$((wc+1))
    done
    sleep 5
    log "系统已就绪（等待 ${wc}s），开始初始化"

    # ========== 崩溃自愈：上次异常退出（系统崩溃/强杀）→ 本次进入安全模式，不锁任何核 ==========
    CRASH_FLAG="$CONFIG_DIR/crash_flag"
    if [ -f "$CRASH_FLAG" ]; then
        SAFE_MODE=1
        log "⚠️ 检测到上次异常退出标记，进入【安全模式】：本次不封锁任何核心（重启一次后自动恢复）"
    else
        SAFE_MODE=0
    fi
    rm -f "$CRASH_FLAG" 2>/dev/null
    # 清理历史版本遗留的 giveup_* 计数文件
    rm -f "$CONFIG_DIR"/giveup_* 2>/dev/null

    # 启动即确定封锁名单（此后每轮循环都会刷新，WebUI 改配置即时生效）
    AUTO_COUNT=$(cfg_int auto_lock_count 1)
    DISABLE_CC=$(cfg_bool disable_core_ctl false)
    LOCK_LIST=$(cfg_val lock_cores auto)
    if [ "$LOCK_LIST" = "auto" ]; then
        LOCK_LIST=$(detect_high)
    else
        # 兼容逗号/空格/顿号分隔（旧配置 6,7 与新配置 6 7 均可）
        LOCK_LIST=$(echo "$LOCK_LIST" | tr ',、' ' ' | tr -s ' ')
    fi

    if [ -z "$LOCK_LIST" ]; then
        log "⚠️ 未检测到可封锁的核心，模块将只做游戏检测，不封锁任何核心"
    elif [ "$lock_logged" = "0" ]; then
        log "封锁核心名单：$LOCK_LIST"
        lock_logged=1
    fi

    # 首次应用（安全模式下不锁核；锁核前预置崩溃标记，20 秒系统正常后解除）
    ENABLED=$(cfg_bool enabled true)
    if [ "$ENABLED" = "true" ] && [ -n "$LOCK_LIST" ] && [ "$SAFE_MODE" = "0" ]; then
        touch "$CRASH_FLAG"
        do_lock
        sleep 20
        rm -f "$CRASH_FLAG"
        state="locked"
        echo "locked|boot" > "$STATE_FILE"
        log "启动完成，日常模式：大核已封锁"
    elif [ "$SAFE_MODE" = "1" ]; then
        echo "safe|-" > "$STATE_FILE"
        log "启动完成（安全模式：未封锁任何核心）"
        state="safe"
    else
        echo "off|-" > "$STATE_FILE"
        log "启动完成（模块禁用或无可封锁核心）"
        state="off"
    fi

    while :; do
        # 自检：模块被删除 / 卸载中 / 被禁用 → 恢复全部并退出（保证无残留）
        if [ ! -f "$MODDIR/module.prop" ] || [ -f "$MODDIR/remove" ] || [ -f "/data/adb/modules/${MODULE_ID}.disable" ]; then
            log "检测到模块已删除/禁用，恢复全部核心并退出"
            cleanup_on_exit
        fi

        ENABLED=$(cfg_bool enabled true)
        # 刷新封锁名单（支持 WebUI 运行时改核心）
        AUTO_COUNT=$(cfg_int auto_lock_count 1)
        DISABLE_CC=$(cfg_bool disable_core_ctl false)
        LOCK_LIST=$(cfg_val lock_cores auto)
        if [ "$LOCK_LIST" = "auto" ]; then
            LOCK_LIST=$(detect_high)
        else
            # 兼容逗号/空格/顿号分隔（旧配置 6,7 与新配置 6 7 均可）
            LOCK_LIST=$(echo "$LOCK_LIST" | tr ',、' ' ' | tr -s ' ')
        fi
        LIMIT_FREQ=$(cfg_bool limit_freq false)
        # poll_interval：唯一的循环周期来源（默认 30 秒，省电优先）
        INTERVAL=$(cfg_int poll_interval 30)
        NO_CHARGE=$(cfg_bool no_lock_charging false)
        GAME_LIST=$(grep -v '^#' "$PACKAGES_FILE" 2>/dev/null | grep -v '^$')

        case "$INTERVAL" in
            ''|*[!0-9]*) INTERVAL=30;;
        esac
        [ "$INTERVAL" -lt 5 ] && INTERVAL=5
        [ "$INTERVAL" -gt 600 ] && INTERVAL=600

        # ---- 主开关 / 安全模式：关闭则全部恢复 ----
        if [ "$ENABLED" != "true" ] || [ "$SAFE_MODE" = "1" ]; then
            if [ "$state" != "off" ] && [ "$state" != "safe" ]; then
                do_unlock
                remove_freq_cap
                last_pkg=""
                if [ "$SAFE_MODE" = "1" ]; then
                    state="safe"
                    echo "safe|-" > "$STATE_FILE"
                    log "进入安全模式：核心全部恢复"
                else
                    state="off"
                    echo "off|-" > "$STATE_FILE"
                    log "模块已禁用，核心全部恢复"
                fi
            fi
            sleep "$INTERVAL"
            continue
        fi

        # ---- 记录上一轮是否为游戏模式（必须在 state 被改写前判断，供间隔逻辑使用） ----
        prev_unlocked=0
        [ "$state" = "unlocked" ] && prev_unlocked=1

        # ---- 屏幕状态（sysfs 免费读取；无 backlight 的设备回退 dumpsys power，每 5 轮一次） ----
        ss=$(screen_sysfs)
        if [ "$ss" = "UNKNOWN" ]; then
            it2=$((it2+1))
            if [ -z "$last_ss" ] || [ $((it2 % 5)) -eq 1 ]; then
                w=$(dumpsys power 2>/dev/null | grep -m1 'mWakefulness=' | sed 's/.*mWakefulness=//')
                if [ "$w" = "Asleep" ] || [ "$w" = "Dozing" ]; then ss="OFF"; else ss="ON"; fi
                last_ss="$ss"
            else
                ss="$last_ss"
            fi
        else
            last_ss="$ss"
        fi

        # ---- 前台应用：仅亮屏时检测；息屏直接锁定（息屏无游戏可点，完全省电不检测） ----
        if [ "$ss" = "OFF" ]; then
            PKGS=""
        else
            PKGS=$(fg_pkgs)
        fi
        pkg=$(echo "$PKGS" | head -1)

        # ---- 决策：是否封锁（息屏一律锁定） ----
        want_lock=yes
        if [ "$ss" != "OFF" ] && [ -n "$GAME_LIST" ]; then
            is_game "$PKGS" && want_lock=no
        fi
        # 充电时不封锁
        if [ "$want_lock" = "yes" ] && [ "$NO_CHARGE" = "true" ] && is_charging; then
            want_lock=no
        fi

        # ---- 执行 ----
        if [ "$want_lock" = "yes" ]; then
            state_changed=0
            [ "$state" != "locked" ] && state_changed=1
            if [ "$state_changed" = "1" ]; then
                log "切换为日常模式：封锁大核（前台: $pkg）"
            fi
            do_lock
            apply_freq_cap
            # 仅在状态切换时打印封锁结果，避免默认 30 秒一轮刷爆日志
            if [ "$state_changed" = "1" ]; then
                oc_now=$(online_count)
                log "封锁结果：[${LOCK_STATE}] 当前在线核心 ${oc_now} 个"
            fi
            state="locked"
            if [ "$last_pkg" != "$pkg" ]; then
                last_pkg="$pkg"
                echo "locked|$pkg" > "$STATE_FILE"
            fi
        else
            if [ "$state" != "unlocked" ]; then
                log "切换为游戏模式：恢复全部核心（前台: $pkg）"
            fi
            do_unlock
            remove_freq_cap
            state="unlocked"
            if [ "$last_pkg" != "$pkg" ]; then
                last_pkg="$pkg"
                echo "unlocked|$pkg" > "$STATE_FILE"
            fi
        fi

        # ---- 间隔：完全由用户配置的 poll_interval 决定，不再有任何硬编码覆盖 ----
        # 只有"刚退出游戏 / 刚进入游戏"的过渡轮用 5 秒短间隔，让锁核状态尽快对齐；
        # 稳态（日常 / 息屏 / 持续游戏）一律按 INTERVAL 走，最大化省电。
        if [ "$state" != "locked" ]; then
            sleep "$INTERVAL"           # 游戏模式：按配置间隔
        elif [ "$prev_unlocked" = "1" ] || [ "$state_changed" = "1" ]; then
            sleep 5                     # 刚封锁完成的过渡轮：快速确认一次
        else
            sleep "$INTERVAL"           # 日常 / 息屏稳态：完整按用户配置间隔
        fi
    done
}

run