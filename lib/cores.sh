# ---------------- 封锁 / 恢复 ----------------

# 逐核渐进封锁。注意：这里【没有】"被系统拉回 N 次就放弃"的机制——
# 被拉回只记录失败，下一轮继续努力封锁，保证用户配置始终真正生效。
LOCK_STATE=""   # 本轮各核封锁结果，仅用于日志
# Shared by daemon and short-lived App commands. Dead owners are reclaimed.
core_guard_enter() {
    local _tries=0 _owner
    while ! mkdir "$CONFIG_DIR/core.lock" 2>/dev/null; do
        _owner=$(cat "$CONFIG_DIR/core.lock/pid" 2>/dev/null)
        if [ -n "$_owner" ] && ! kill -0 "$_owner" 2>/dev/null; then
            rm -f "$CONFIG_DIR/core.lock/pid"
            rmdir "$CONFIG_DIR/core.lock" 2>/dev/null
        fi
        _tries=$((_tries+1))
        [ "$_tries" -ge 15 ] && return 1
        sleep 1
    done
    echo $$ > "$CONFIG_DIR/core.lock/pid"
}
core_guard_leave() {
    rm -f "$CONFIG_DIR/core.lock/pid"
    rmdir "$CONFIG_DIR/core.lock" 2>/dev/null
}
# A driver may change sibling cores while offlining a selected core.
# Reconcile the complement only after all requested cores have been offlined.
core_restore_except() {
    local _core
    for _core in $(all_cpus); do
        [ "$_core" = 0 ] && continue
        case " $1 " in *" $_core "*) continue;; esac
        cpu_online "$_core" || set_cpu "$_core" 1
    done
}
# do_lock [指定名单]
# 无参数：日常锁核，名单 = 自动/手动名单 + 温度额外名单。
# 有参数：只锁名单内的核心，其余全部上线（游戏锁核专用，双向切换：
#         勾了哪个就锁哪个，没勾的直接解开），不叠加温度额外名单。
do_lock() {
    local c _desired _manual _pass
    LOCK_STATE=""
    core_guard_enter || { log "核心控制繁忙，本轮跳过"; return 1; }
    if [ "$DISABLE_CC" = "true" ]; then disable_core_ctl; else restore_core_ctl; fi
    if [ -n "$1" ]; then
        # 指定名单模式（游戏）：名单即全部真相，未列出的核一律放出来。
        # V2.4.1：游戏态不合并主页手动名单——进游戏时主页封的核也一起放开，
        # 只为「游戏保持锁核」勾选的核保持离线（勾哪个锁哪个，没勾的全解）。
        # 退出游戏回到日常后，主页手动名单由无参 do_lock 重新接管。
        _desired=$(printf '%s' "$1" | tr ',、' ' ' | tr -s ' ')
    else
        _manual=$(manual_list | xargs)
        # A manual choice replaces automatic suggestions, so selecting CPU5 does not add CPU7.
        if [ -n "$_manual" ] && [ "$(cfg_val lock_cores auto)" = auto ]; then
            _desired="$_manual"
        else
            _desired="$LOCK_LIST $_manual"
        fi
        # 温度额外名单在手动 / 自动日常名单确定后合并，避免被手动模式覆盖。
        _desired="$_desired $THERMAL_EXTRA_ACTIVE"
    fi
    for c in $_desired; do
        case "$c" in ''|0|*[!0-9]*) continue;; esac
        if cpu_online "$c"; then set_cpu "$c" 0 && sleep 1; fi
    done
    # 降温放核的关键：core_restore_except 会把不在 _desired 里的核一律拉回在线。
    # 旧版缺陷是温度额外核可能同时存在于日常名单里，导致 THERMAL_EXTRA_ACTIVE
    # 清空后仍被 LOCK_LIST 拽住；这里改为降温时先从日常名单里剔除额外核再锁。
    for _pass in 1 2 3; do core_restore_except "$_desired"; done
    for c in $_desired; do
        case "$c" in ''|0|*[!0-9]*) continue;; esac
        if cpu_online "$c"; then LOCK_STATE="${LOCK_STATE}${c}:fail "
        else LOCK_STATE="${LOCK_STATE}${c}:ok "; fi
    done
    core_guard_leave
}
# do_unlock [保留名单]
# 无参数：全部核心上线（原有语义，所有旧调用点行为完全不变）。
# 有参数：只把名单内的核心保持离线（游戏锁核），其余核心恢复上线。
do_unlock() {
    local c _pass _missing _keep
    # 名单归一化：逗号/顿号转空格、压缩空格、去掉非数字项
    _keep=$(printf '%s' "$1" | tr ',、' ' ' | tr -s ' ')
    for c in $_keep; do
        case "$c" in ''|*[!0-9]*) _keep=""; break;; esac
    done
    UNLOCK_FAILED=""
    core_guard_enter || { UNLOCK_FAILED="busy"; return 1; }
    # Keep core_ctl disabled while full-core performance is requested.
    # Its original values stay in the backup and are restored on exit/daily policy.
    disable_core_ctl
    for _pass in 1 2 3; do
        core_restore_except "$_keep"
        _missing=""
        for c in $(all_cpus); do
            [ "$c" = 0 ] && continue
            case " $_keep " in *" $c "*) continue;; esac
            cpu_online "$c" || _missing="$_missing $c"
        done
        [ -z "$_missing" ] && break
        [ "$_pass" -lt 3 ] && sleep 1
    done
    UNLOCK_FAILED="$_missing"
    core_guard_leave
    if [ -n "$UNLOCK_FAILED" ]; then
        log "恢复未完成，仍离线:$UNLOCK_FAILED${_keep:+（游戏锁核名单:$_keep）}"
        return 1
    fi
    return 0
}