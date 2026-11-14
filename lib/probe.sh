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

# ---------------- 前台应用检测（v2.5.3：五路并集，窗口清单优先） ----------------
# 为什么要重写（实测依据，2026-11 真机 dumpsys 取证）：
#   1) 小窗/分屏/画中画时，mCurrentFocus 会被浮窗抢走 —— 侧边栏呼出瞬间焦点是
#      com.coloros.smartsidebar，QQ 小窗浮起后焦点是 com.tencent.mobileqq，而
#      全屏主窗口仍是 mObscuringWindow / mTopFullscreenOpaqueWindowState。
#      => 只读焦点字段必然把「小窗里的游戏」判成非游戏，导致误锁核+误限频（卡顿主因）。
#   2) 旧实现方式1一旦拿到任何包名就 return，短路掉后续所有补充来源。
#      => 改为「多路合并」，所有来源的包名取并集，任一命中游戏名单即算游戏。
#   3) 窗口清单里 package= 字段稳定可读，且每个窗口带 isReadyForDisplay()。
#      => 以「可见窗口集合」为主判据，覆盖小窗、分屏、画中画、悬浮窗等全部形态。

# 从一行文本中提取包名：优先取 "包名/Activity" 的包名，否则取首个形似包名的 token
_fg_extract() {
    sed -E 's/.*[ {]([a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+)\/[^ ]*.*/\1/' \
        | grep -oE '[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+' | head -1
}

# 系统级窗口包名：不是「用户应用」，参与前台判定只会造成误判，一律排除。
#   com.coloros.smartsidebar  侧边栏/浮球（实测会抢焦点）
#   com.android.systemui      状态栏/导航栏/通知栏/壁纸
#   android                   系统对话框/拖拽目标
#   com.tencent.wetype 等输入法由 mIsImWindow=true 排除，无需在此列举
_fg_is_system_pkg() {
    case "$1" in
        com.coloros.smartsidebar|com.oplus.smartsidebar) return 0;;
        com.android.systemui|com.oplus.systemui) return 0;;
        android|com.android.settings.intelligence) return 0;;
        com.android.launcher|com.oplus.launcher|com.coloros.launcher) return 0;;
    esac
    return 1
}

# Visible windows include split-screen, floating windows and picture-in-picture.
# Surface alone or INVISIBLE (0x4) never proves current visibility.
_fg_window_pkgs() {
    dumpsys window windows 2>/dev/null | awk '
        function field(line,key, v) {
            v=substr(line,index(line,key "=")+length(key)+1); sub("[^a-zA-Z0-9x].*","",v); return v
        }
        function emit() {
            if (pkg == "" || isim == "true" || iswp == "true") return
            if (vis != "" && vis != "0x0" && vis != "0") return
            if (onscreen == "false" || visible == "false" || policy == "false") return
            if (ready == "true" || onscreen == "true" || visible == "true" || (surf == "true" && (vis == "0x0" || vis == "0"))) print pkg
        }
        /^[[:space:]]*Window #[0-9]+ / {
            emit(); pkg=""; isim=""; iswp=""; ready=""; surf=""; vis=""; onscreen=""; visible=""; policy=""
        }
        /package=/ { if (match($0,/package=[a-zA-Z0-9_.]+/)) pkg=substr($0,RSTART+8,RLENGTH-8) }
        /mIsImWindow=/ { isim=field($0,"mIsImWindow") }
        /mIsWallpaper=/ { iswp=field($0,"mIsWallpaper") }
        /isReadyForDisplay\(\)=/ { ready=field($0,"isReadyForDisplay()") }
        /mHasSurface=/ { surf=field($0,"mHasSurface") }
        /mViewVisibility=/ { vis=field($0,"mViewVisibility") }
        /isOnScreen=/ { onscreen=field($0,"isOnScreen") }
        /isVisible=/ { visible=field($0,"isVisible") }
        /mPolicyVisibility=/ { policy=field($0,"mPolicyVisibility") }
        END { emit() }
    '
}

fg_pkgs() {
    # V2.5.4 需求 3：是否额外扫描后台存活进程，由 fg_only_detect 决定。
    # 默认 true（仅前台）—— 前台四路已经能覆盖绝大多数场景，且省掉一次全进程扫描。
    # 用户主动关掉该开关时，才追加第 5 路（小窗补盲）。
    fg_pkgs_fg_only
    if [ "$(cfg_bool fg_only_detect true)" = "true" ]; then
        return 0
    fi
    _p5=$(bg_pkgs)
    [ -n "$_p5" ] && printf '%s\n' "$_p5"
}

# V2.5.4 需求 1：只输出「前台四路」结果，不含 /proc 全进程扫描。
# 录屏 / 相机的解封判据必须走这里 —— 后台驻留的相机进程不再触发全核恢复。
fg_pkgs_fg_only() {
    # 【第1路·主判据】可见窗口清单 —— 小窗/分屏/画中画/全屏全覆盖
    _p1=$(_fg_window_pkgs | while IFS= read -r _p; do
        [ -z "$_p" ] && continue
        _fg_is_system_pkg "$_p" || echo "$_p"
    done | sort -u)

    # 【第2路·焦点补充】dumpsys window 的顶层字段
    # 注意：小窗时会指向小窗包名，这恰好是有用信号（说明该应用确实在前台），
    #       因此这里不再是「短路返回」，而是并集的一部分。
    _p2=$(dumpsys window 2>/dev/null \
        | grep -E '^[[:space:]]*(mCurrentFocus|mFocusedWindow)=' \
        | sed -E 's/.*[ {]([a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+)\/[^ ]*.*/\1/' \
        | grep -E '^[a-zA-Z][a-zA-Z0-9_.]*$' | grep -v '^null$' \
        | while IFS= read -r _p; do
            [ -z "$_p" ] && continue
            _fg_is_system_pkg "$_p" || echo "$_p"
        done | sort -u)

    # 【第3路·Activity 栈】ColorOS 上部分场景只有这里准（如游戏空间接管）
    # v2.5.1（省电）：这两路定位是「兜底」，只在前面都没拿到包名时才执行。
    # 旧版四路无条件全跑，每轮要 fork 4 个 dumpsys 并各自灌全量输出进管道，
    # 是主循环最大的单项开销（实测单次 fg_pkgs 可占几十到上百毫秒）。
    # _p1（可见窗口）在 ColorOS 上命中率极高，_p2（焦点字段）再补一层，
    # 两者都空才说明确实取不到，此时兜底才有意义。
    _p3=""
    _p4=""
    if [ -z "$_p1" ] && [ -z "$_p2" ]; then
        _p3=$(dumpsys activity activities 2>/dev/null \
            | grep -m1 -E 'mResumedActivity|topResumedActivity|ResumedActivity' \
            | _fg_extract)

        # 【第4路·activity 顶层兜底】
        [ -z "$_p3" ] && _p4=$(dumpsys activity 2>/dev/null \
            | grep -m1 -E 'mResumedActivity|topResumedActivity|ResumedActivity' \
            | _fg_extract)
    fi

    # 四路合并取并集（去重）。全部为空时输出空，由调用方按非游戏处理。
    {
        [ -n "$_p1" ] && printf '%s\n' "$_p1"
        [ -n "$_p2" ] && printf '%s\n' "$_p2"
        [ -n "$_p3" ] && printf '%s\n' "$_p3"
        [ -n "$_p4" ] && printf '%s\n' "$_p4"
    } | grep -v '^$' | sort -u
}

# 【第5路·小窗补盲，v2.5.3】读取「全部存活进程的包名」，用于小窗/分屏/画中画
# 场景下目标应用不进可见窗口清单、也不持有焦点时的兜底识别。
# 实测数据（本机 PLR110 / ColorOS，2026-11，均为三次均值）：
#   dumpsys activity processes   29~35 ms / 788 KB  —— 太贵，弃用
#   ps -A -o NAME + grep         30~44 ms / 890 行  —— 需要 fork toybox，不是 root 快路径
#   cat /proc/[0-9]*/comm        21~24 ms           —— 看似最快，但 comm 被内核硬截断 15 字符
#                                                      (com.tencent.mobileqq -> encent.mobileqq)
#                                                       → 不能用于包名精确匹配，已否决
#   cat /proc/[0-9]*/cmdline     25~28 ms           —— 采用：包名完整，不 fork
#   逐 /proc 目录 for + cat       4500 ms           —— 绝对不能这么写（每进程 fork 数次）
# 关键：必须写成「单次 cat 通配 + 管道过滤」，绝不能循环 fork。
# cmdline 用 \0 分隔参数，tr 转成换行后每行一个参数，用 grep -x 精确匹配包名。
installed_running_pkgs() {
    # Installed system and user apps only; process arguments are not package identities.
    _cg_user=$(am get-current-user 2>/dev/null)
    case "$_cg_user" in ''|*[!0-9]*) _cg_user=0;; esac
    _cg_installed=$(pm list packages --user "$_cg_user" 2>/dev/null | sed -n 's/^package://p')
    [ -n "$_cg_installed" ] || return 0
    awk -v installed="$_cg_installed" 'BEGIN { n=split(installed,a,"\n"); for(i=1;i<=n;i++) ok[a[i]]=1 } ok[$0] && !seen[$0]++' | sort -u
}
bg_pkgs() {
    cat /proc/[0-9]*/cmdline 2>/dev/null | tr '\000' '\n' | sed -nE 's/^([a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+)(:[a-zA-Z0-9_.-]+)?$/\1/p' | installed_running_pkgs
}
scan_publish() {
    _scan_mode=foreground
    [ "$(cfg_bool fg_only_detect true)" = true ] || _scan_mode=all
    _scan_packages=$(printf '%s\n' "$PKGS" | sed '/^$/d' | installed_running_pkgs | tr '\n' ',')
    printf '%s|%s|%s|%s|%s\n' "$_scan_mode" "$(date +%s)" "$$" "${1:-active}" "$_scan_packages" > "$CONFIG_DIR/scan.state.$$.tmp"
    mv -f "$CONFIG_DIR/scan.state.$$.tmp" "$CONFIG_DIR/scan.state"
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

# Optional strategy mask; baseline game detection and freezing are independent.
policy_active_mask() {
    [ "$(cfg_bool policy_master_enabled false)" = true ] || return 0
    _pam=""
    for _strategy_key in capture_boost no_lock_charging temperature_enabled game_lock_enable; do
        [ "$(cfg_bool "$_strategy_key" false)" != true ] || _pam="$_pam $_strategy_key"
    done
    printf '%s' "$_pam"
}

# ---------------- 屏幕 / 充电状态 ----------------
is_charging() {
    s=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
    if [ "$s" = "Charging" ] || [ "$s" = "Full" ]; then return 0; fi
    dumpsys battery 2>/dev/null | grep -qE 'AC powered: true|USB powered: true|Wireless powered: true'
}

# Call directly in the parent shell so even an empty result is cached this round.
fg_refresh() {
    [ "${_FG_ROUND_READY:-0}" = 1 ] && return 0
    PKGS=$(fg_pkgs | sort -u)
    scan_publish active
    _FG_ROUND_READY=1
}

# Optional strategies only. Baseline game polling, frequency and freezing are independent.
strategy_enabled() {
    [ "$(cfg_bool policy_master_enabled false)" = true ] || return 1
    for _strategy_key in capture_boost no_lock_charging temperature_enabled game_lock_enable; do
        [ "$(cfg_bool "$_strategy_key" false)" != true ] || return 0
    done
    return 1
}
