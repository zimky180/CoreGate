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

# ---------------- 屏幕 / 充电状态 ----------------
is_charging() {
    s=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
    if [ "$s" = "Charging" ] || [ "$s" = "Full" ]; then return 0; fi
    dumpsys battery 2>/dev/null | grep -qE 'AC powered: true|USB powered: true|Wireless powered: true'
}

