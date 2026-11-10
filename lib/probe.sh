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

# ---------------- 前台应用检测（多路回退：覆盖 ColorOS 各类前台字段） ----------------
# 从一行文本中提取包名：优先取 "包名/Activity" 的包名，否则取首个形似包名的 token
_fg_extract() {
    sed -E 's/.*[ {]([a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+)\/[^ ]*.*/\1/' \
        | grep -oE '[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+' | head -1
}
fg_pkgs() {
    # 方式1：dumpsys window 多字段（全屏游戏/游戏空间/挂屏/焦点，取所有命中的包名）
    out=$(dumpsys window 2>/dev/null \
        | grep -E 'mCurrentFocus|mFocusedApp|mHoldScreenWindow|mTopFullscreenOpaque|mObscuringWindow|mLastFocusedWindow|mFocusedWindow' \
        | sed -E 's/.* ([a-zA-Z0-9.]+)\/.*/\1/' \
        | grep -E '^[a-zA-Z][a-zA-Z0-9_.]*$' | grep -v '^null$' | sort -u)
    if [ -n "$out" ]; then
        echo "$out"
        return
    fi
    # 方式2：activity 栈里的当前活跃 Activity（ColorOS 最可靠）
    out=$(dumpsys activity activities 2>/dev/null \
        | grep -m1 -E 'mResumedActivity|topResumedActivity|ResumedActivity' \
        | _fg_extract)
    [ -n "$out" ] && { echo "$out"; return; }
    # 方式3：dumpsys activity 的顶层信息（部分机型只有这里准）
    out=$(dumpsys activity 2>/dev/null \
        | grep -m1 -E 'mResumedActivity|topResumedActivity|ResumedActivity' \
        | _fg_extract)
    [ -n "$out" ] && { echo "$out"; return; }
    # 方式4：window 的焦点兜底
    out=$(dumpsys window 2>/dev/null \
        | grep -m1 -E 'mCurrentFocus|mFocusedApp' \
        | _fg_extract)
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
is_capture() {  # $1=多行候选包名，任一精确命中即录屏/相机（需要全核在线）
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        case "$pkg" in null) continue;; esac
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            case "$line" in \#*) continue;; esac
            [ "$pkg" = "$line" ] && return 0
        done <<LIST
$CAPTURE_LIST
LIST
    done <<PKGS
$1
PKGS
    return 1
}

# ---------------- 策略活跃度判定（低功耗短路用） ----------------
# 目的：当用户把所有策略开关都关掉时，主循环不该再去 dumpsys / pm / 读传感器。
#       sh 进程本身的开销必须尽可能低，否则"省电模块自己耗电"就本末倒置。
#
# 逐位含义（任一为真 → 策略活跃，需要每轮工作）：
#   cap          录屏/相机自动恢复        capture_boost
#   charge       充电时不锁核             no_lock_charging
#   thermal      温度策略                 temperature_enabled
#   game         游戏自动恢复（名单非空） packages.txt
#   gamelock     游戏保持锁核（开关+名单）game_lock_enable + game_lock_cores
#   freq         日常限频                limit_freq
#   freeze       组件冻结（任一组开启）    freeze_grp_*
#
# 注意：核心封锁/恢复本身（enabled + lock_cores）始终生效，但它是幂等的——
#       目标状态没变时重复 do_lock/do_unlock 只是白跑子进程，由调用方处理。
policy_active_mask() {
    _pam=""
    [ "$(cfg_bool capture_boost false)" = "true" ] && _pam="$_pam cap"
    [ "$(cfg_bool no_lock_charging false)" = "true" ] && _pam="$_pam charge"
    [ "$(cfg_bool temperature_enabled false)" = "true" ] && _pam="$_pam thermal"
    [ -n "$(grep -v '^#' "$PACKAGES_FILE" 2>/dev/null | grep -v '^$' | head -1)" ] && _pam="$_pam game"
    # 游戏保持锁核：开关打开且名单非空才需要每轮识别游戏
    if [ "$(cfg_bool game_lock_enable false)" = "true" ]; then
        _pgl=$(cfg_val game_lock_cores "")
        _pgl=$(printf '%s' "$_pgl" | tr ',、' ' ' | tr -s ' ')
        [ -n "$_pgl" ] && _pam="$_pam gamelock"
    fi
    [ "$(cfg_bool limit_freq false)" = "true" ] && _pam="$_pam freq"
    _pg_on=0
    for _pg in log media cloud diag ad self ai voice games themes search; do
        if [ "$(cfg_bool "freeze_grp_$_pg" false)" = "true" ]; then _pg_on=1; break; fi
    done
    [ "$_pg_on" = "1" ] && _pam="$_pam freeze"
    # 手动单包冻结也要算活跃（否则用户手动冻的包永远不会被同步）
    [ ! -f "$FREEZE_MANUAL" ] || [ ! -s "$FREEZE_MANUAL" ] || _pam="$_pam freeze"
    [ ! -f "$FREEZE_STATE" ] || [ ! -s "$FREEZE_STATE" ] || _pam="$_pam freeze"
    printf '%s' "$_pam"
}

# ---------------- 屏幕 / 充电状态 ----------------
is_charging() {
    s=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
    if [ "$s" = "Charging" ] || [ "$s" = "Full" ]; then return 0; fi
    dumpsys battery 2>/dev/null | grep -qE 'AC powered: true|USB powered: true|Wireless powered: true'
}
