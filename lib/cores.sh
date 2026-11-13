# ---------------- 封锁 / 恢复 ----------------

# 逐核渐进封锁。注意：这里【没有】"被系统拉回 N 次就放弃"的机制——
# 被拉回只记录失败，下一轮继续努力封锁，保证用户配置始终真正生效。
LOCK_STATE=""   # 本轮各核封锁结果，仅用于日志
# Shared by daemon and short-lived App commands. Dead owners are reclaimed.
core_guard_enter() {
    local _tries=0 _owner
    if [ "${CORE_GUARD_DEPTH:-0}" -gt 0 ] && [ "$(cat "$CONFIG_DIR/core.lock/pid" 2>/dev/null)" = "$$" ]; then
        CORE_GUARD_DEPTH=$((CORE_GUARD_DEPTH + 1))
        return 0
    fi
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
    CORE_GUARD_DEPTH=1
}
core_guard_leave() {
    [ "$(cat "$CONFIG_DIR/core.lock/pid" 2>/dev/null)" = "$$" ] || return 0
    if [ "${CORE_GUARD_DEPTH:-0}" -gt 1 ]; then
        CORE_GUARD_DEPTH=$((CORE_GUARD_DEPTH - 1))
        return 0
    fi
    CORE_GUARD_DEPTH=0
    rm -f "$CONFIG_DIR/core.lock/pid"
    rmdir "$CONFIG_DIR/core.lock" 2>/dev/null
}
# A driver may change sibling cores while offlining a selected core.
# Restore the complement before offlining the requested cores.
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
# 有参数：重锁游戏名单和主页手动名单，恢复其余核心，不叠加温度额外名单。
do_lock() {
    local c _desired _manual _pass _failed
    LOCK_STATE=""
    core_guard_enter || { log "核心控制繁忙，本轮跳过"; return 1; }
    if [ -n "$1" ] || [ "$DISABLE_CC" = "true" ]; then disable_core_ctl; else restore_core_ctl; fi
    if [ -n "$1" ]; then
        # 游戏态重锁策略名单与主页手动标红名单；退出游戏由日常名单接管。
        _manual=$(manual_list | xargs)
        _desired=$(printf '%s' "$1 $_manual" | tr ',、' ' ' | tr -s ' ')
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
    # Restore siblings before offlining selected cores: bringing a sibling online
    # may bring the selected core online as a driver side effect.
    _desired=$(printf '%s' "$_desired" | xargs)
    for _pass in 1 2 3; do
        core_restore_except "$_desired"
        for c in $_desired; do
            case "$c" in ''|0|*[!0-9]*) continue;; esac
            if cpu_online "$c"; then set_cpu "$c" 0 && sleep 1; fi
        done
    done
    _failed=""
    for c in $_desired; do
        case "$c" in ''|0|*[!0-9]*) continue;; esac
        if cpu_online "$c"; then LOCK_STATE="${LOCK_STATE}${c}:fail "; _failed="$_failed $c"
        else LOCK_STATE="${LOCK_STATE}${c}:ok "; fi
    done
    core_guard_leave
    if [ -n "$_failed" ]; then
        log "封锁未完成，仍在线:$_failed"
        return 1
    fi
    return 0
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