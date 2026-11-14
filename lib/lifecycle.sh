# ---------------- 完全恢复（可逆性保证） ----------------
# 卸载 / 删除 / 禁用时：恢复核心、频率、core_ctl 原始值，不留任何运行残留
restore_all() {
    # 卸载清空手动意图，避免以后重新启用时沿用旧封锁。
    [ "$1" = "preserve" ] || manual_clear
    rm -f "$THERMAL_STATE_FILE" "$THERMAL_STATE_FILE.$$.tmp"
    LOCK_LIST=$(all_cpus)
    do_unlock
    remove_freq_cap
    restore_core_ctl
    # 组件停用同样必须零残留：卸载/退出时把被本模块关掉的系统组件逐个启用回来
    freeze_restore_all
}

# ---------------- v2.5.6 手动恢复意图（UNLOCK_HOLD）有效期判定 ----------------
# 背景：unlock_once / --lock-once / --core-off 都是独立进程的一次性命令，
# 它们不写守护进程内存里的 state，所以守护进程「看不见」用户刚做了什么。
# 修法：手动恢复时由 commands.sh 落一个 UNLOCK_HOLD 标记文件，守护进程读标记。
#
# 两种有效期语义（关键，不可一刀切）：
#   enabled=false（固态模式）：标记存在即永久尊重，直到用户再次手动封锁
#       （lock_once / --core-off 会 rm 掉标记）。固态模式的语义就是「不轮询、
#        按用户配置保持」，用户手动恢复了却马上被锁回去，纯属违背意图。
#   enabled=true（日常轮询）：只尊重 HOLD_GRACE 秒。日常轮询的职责是持续省电，
#       若永久尊重标记，用户一次手动恢复就等于永久关掉省电，属于功能失效。
#       所以过了宽限期就让轮询自动接管，标记顺手删掉。
# 返回：0=标记活跃（本次应跳过 do_lock），1=无标记或已过期。
HOLD_GRACE=90
unlock_hold_active() {
    [ -f "$UNLOCK_HOLD" ] || return 1
    # 固态模式：永久尊重
    if [ "$ENABLED" != "true" ]; then
        return 0
    fi
    # 日常轮询：比对时间戳，超过宽限期即失效
    _hold_ts=$(cat "$UNLOCK_HOLD" 2>/dev/null)
    case "$_hold_ts" in
        ''|*[!0-9]*) _hold_ts=0;;
    esac
    _now_ts=$(date +%s 2>/dev/null)
    case "$_now_ts" in
        ''|*[!0-9]*) _now_ts=0;;
    esac
    # 时间戳读不到 / 系统时钟异常：按「已过期」处理，让轮询正常接管，
    # 避免一个坏文件把省电功能永久废掉。
    if [ "$_hold_ts" -le 0 ] || [ "$_now_ts" -le 0 ]; then
        rm -f "$UNLOCK_HOLD" 2>/dev/null
        return 1
    fi
    _hold_age=$(( _now_ts - _hold_ts ))
    if [ "$_hold_age" -lt "$HOLD_GRACE" ]; then
        return 0
    fi
    rm -f "$UNLOCK_HOLD" 2>/dev/null
    return 1
}

# Explicit shutdown cannot be revived within the same boot.
daemon_revive() {
    echo "CORE_GATE_STOPPED: restart device to resume"
    return 1
}

TRAP_DONE=0
# 【关键】只有守护主循环（run）才需要「退出即全量还原」。
# 命令行单次调用（--freeze-add / --set-freeze / --freeze-sync / --freeze-status ...）
# 若也触发 EXIT trap，就会执行 restore_all → freeze_restore_all
# → rm -f "$FREEZE_STATE"，把刚写好的冻结记录连同刚冻结的包一起抹掉，
# 表现为「冻结返回成功，但 freeze.state 不存在 / 开关立刻失效」。
# 这类假象极难排查，因此 trap 默认不装，进 run() 时才 TRAP_ARMED=1。
TRAP_ARMED=0
cleanup_on_exit() {
    [ "$TRAP_ARMED" = "1" ] || return 0
    [ "$TRAP_DONE" = "1" ] && exit 0
    TRAP_DONE=1
    if [ "$(cat "$CONFIG_DIR/core.lock/pid" 2>/dev/null)" = "$$" ]; then core_guard_leave; fi
    _exit_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    if [ -f "$MODDIR/module.prop" ] && [ ! -f "$MODDIR/remove" ] && [ ! -f "$MODDIR/disable" ]; then
        if [ -n "$_exit_boot" ] && [ "$(cat "$CONFIG_DIR/stopped.boot" 2>/dev/null)" = "$_exit_boot" ]; then
            # Explicit stop preserves current CPU/frequency/freeze state.
            echo "dead" > "$STATE_FILE"
        else
            restore_all preserve
        fi
    else
        restore_all
    fi
    rm -f "$PID_FILE" "$CONFIG_DIR/crash_flag"
    log "CoreGate.sh 已退出（显式停运保留现场；禁用/删除执行完整恢复）"
    exit 0
}
trap cleanup_on_exit TERM INT EXIT

run() {
    _current_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    [ -n "$_current_boot" ] || return 1
    if [ "$(cat "$CONFIG_DIR/stopped.boot" 2>/dev/null)" = "$_current_boot" ]; then
        log "CoreGate.sh 已停止，仅重启后恢复"
        return 1
    fi
    if [ -s "$CONFIG_DIR/stopped.boot" ]; then
        # A previous-boot explicit stop resumes only after a real reboot.
        cfg_set_bool enabled true || return 1
        rm -f "$CONFIG_DIR/stopped.boot"
    fi
    cfg_set_bool daemon_alive true
    # 进入守护主循环：此后退出（TERM/INT/EXIT）才需要全量还原，武装 trap。
    TRAP_ARMED=1
    freeze_wait_pms
    echo $$ > "$PID_FILE" 2>/dev/null
    rm -f "$CONFIG_DIR/high_cores"
    state=""; pkg=""; want_lock=""; last_pkg=""; lock_logged=0; ss=""; it2=0; last_ss=""
    prev_unlocked=0; oc_now=""
    prev_game=0

    # ========== 开机延迟：等系统完全启动再锁核（防止干扰开机导致卡机/崩溃） ==========
    # V2.5.0（Bug A）：先删掉上一次开机残留的 boot_wait。该文件只在下面写、过去从不删，
    # 于是旧数据会跨开机存活，被当成本次开机的等待记录展示（「明明早启动了还显示等待中」）。
    # APK 侧另有 bootWaitTs 新鲜度兜底，这里做模块侧的第一道清理。
    rm -f "$CONFIG_DIR/boot_wait" 2>/dev/null
    wc=0
    while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$wc" -lt 90 ]; do
        sleep 1
        wc=$((wc+1))
    done
    sleep 5
    log "系统已就绪（等待 ${wc}s），开始初始化"
    # ========== 开机等待可视化：把本次实际等待结果落盘给 APK 读 ==========
    # APK 首页「运行概览」在守护进程还没起来的空窗期里，会显示
    # 「模块正在等待系统启动完成」。没有这个文件时 APK 只能显示
    # 「守护进程未启动」，用户会误以为模块坏了 —— 这正是本次新增的目的。
    # 格式：poll=<轮询秒数> fixed=5 total=<轮询+固定> ts=<完成时刻 epoch>
    # 每轮 init 都刷新，守护进程存活后 APK 不再展示该提示。
    _boot_total=$((wc + 5))
    echo "poll=$wc fixed=5 total=$_boot_total ts=$(date +%s)" > "$CONFIG_DIR/boot_wait" 2>/dev/null

    # ========== 清理「守护进程已手动杀死」标记 ==========
    # 【历史】V2.5.0（Bug C）起：APK 里点「杀死守护进程」会 touch 一个 daemon.dead 标记。
    # 【V2.5.9 更正】该标记不再是死局，也不再宣称「只能重启」：
    #   · 用户可在设置页卡片一点「重新拉起进程」当场自愈（见 daemon_revive）；
    #   · 重启设备时本脚本重新跑起来，同样会把标记清掉 —— 两条路都通。
    if [ -f "$CONFIG_DIR/daemon.dead" ]; then
        rm -f "$CONFIG_DIR/daemon.dead" 2>/dev/null
        log "检测到 daemon.dead 标记（上次会话手动杀死守护进程），已清除，恢复正常运行"
    fi

    # ========== 开机强制恢复 sh 轮询开关（v2.5.9，用户硬性要求） ==========
    # 【需求】用户在 App 里关掉「启用 sh 轮询进程」后，一旦重启设备，
    #         该开关必须自动恢复为「开启」，不必手动再去点一次。
    # 【为什么放在这里】必须排在 daemon.dead 清理之后、崩溃自愈判定之前：
    #   · daemon.dead 已在上方删掉，此处 enabled=true 不会被 UI 判死逻辑压制；
    #   · 崩溃自愈若判定为 SAFE_MODE，会在后面把 SAFE 标记置上，
    #     那时 ENABLED 仍为 true 但策略层按安全模式不锁核，语义正确。
    # 【为什么先判 true 再写】避免每次开机都无谓地重写 config.json：
    #   重写会 bump mtime，导致 APK 侧的配置缓存失效、多一次不必要的读盘。
    #   cfg_bool 缺键时默认 true（见 config.sh），所以「缺键」也视为已开启，不写。
    # 【写盘用 cfg_set_bool】它会置 _CG_CACHE_DIRTY=1，保证本轮 cfg_reload
    #   立刻读到新值，不会因为哨兵文件的 mtime 判断而沿用旧缓存。
    _boot_enabled=$(cfg_bool enabled true)
    if [ "$_boot_enabled" != "true" ]; then
        if cfg_set_bool enabled true; then
            log "开机自愈：sh 轮询开关上次为关闭状态（$CONFIG_DIR/enabled=false），已自动恢复为开启"
        else
            # 写盘失败（只读 / 磁盘异常）时不能静默：记日志，并让本轮直接用 true 跑，
            # 至少本次开机的行为仍然符合用户「重启后自动开启」的预期。
            log "开机自愈：sh 轮询开关恢复开启失败（config.json 不可写），本次开机按开启运行"
        fi
    fi
    unset _boot_enabled

    # ========== 崩溃自愈：上次异常退出（系统崩溃/强杀）→ 本次进入安全模式，不锁任何核 ==========
    CRASH_FLAG="$CONFIG_DIR/crash_flag"
    BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    if [ -n "$BOOT_ID" ] && [ "$(cat "$CRASH_FLAG" 2>/dev/null)" = "$BOOT_ID" ]; then
        SAFE_MODE=1
        log "⚠️ 检测到上次异常退出标记，进入【安全模式】：本次不封锁任何核心（重启一次后自动恢复）"
    else
        SAFE_MODE=0
    fi
    # 当前进程自行留标记；正常退出由 cleanup_on_exit 清除。
    # 同一次开机被强杀后再启动会进入安全模式，无需看门狗。
    [ -n "$BOOT_ID" ] && printf '%s\n' "$BOOT_ID" > "$CRASH_FLAG" 2>/dev/null
    # 清理历史版本遗留的 giveup_* 计数文件
    rm -f "$CONFIG_DIR"/giveup_* 2>/dev/null

    # 启动即确定封锁名单（此后每轮循环都会刷新，App 改配置即时生效）
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
    # 首次应用：总开关必须在第一次策略采样之前加载。
    cfg_reload
    ENABLED=$(cfg_bool enabled true)
    LIMIT_FREQ=$(cfg_bool limit_freq false)
    POLICY_MASTER=false
    strategy_enabled && POLICY_MASTER=true
    # Frequency control restored byte-for-byte from v2.4.2; no factory baseline probing.
    thermal_update
    GAME_LIST=$(grep -v '^#' "$PACKAGES_FILE" 2>/dev/null | grep -v '^$')
    GAME_ACTIVE=0
    # 游戏锁核：进游戏时重锁策略名单和主页手动名单，其余上线。
    GAME_LOCK_ENABLE=$(cfg_bool game_lock_enable false)
    GAME_LOCK_LIST=$(cfg_val game_lock_cores "")
    GAME_LOCK_LIST=$(printf '%s' "$GAME_LOCK_LIST" | tr ',、' ' ' | tr -s ' ' | xargs)
    PKGS=""
    if [ "$ENABLED" = true ] && [ "$SAFE_MODE" != 1 ]; then fg_refresh; fi
    if [ "$ENABLED" = true ] && [ "$SAFE_MODE" != 1 ] && [ -n "$GAME_LIST" ] && is_game "$PKGS"; then GAME_ACTIVE=1; fi
    want_lock=yes
    [ "$GAME_ACTIVE" = 1 ] && want_lock=no
    CAPTURE_BOOST=$(cfg_bool capture_boost false)
    CAPTURE_LIST=""
    if [ "$POLICY_MASTER" = "true" ] && [ "$CAPTURE_BOOST" = true ]; then
        CAPTURE_LIST=$(grep -v '^#' "$CAPTURE_FILE" 2>/dev/null | grep -v '^$')
        [ -n "$CAPTURE_LIST" ] || CAPTURE_LIST="$CAPTURE_DEFAULT"
        [ -n "$CAPTURE_LIST" ] && is_capture "$PKGS" && want_lock=no
    fi
    NO_CHARGE=$(cfg_bool no_lock_charging false)
    [ "$POLICY_MASTER" = "true" ] && [ "$NO_CHARGE" = true ] && is_charging && want_lock=no
    thermal_decide
    if [ "$want_lock" = no ] && [ "$ENABLED" = true ] && [ "$SAFE_MODE" = 0 ]; then
        if [ "$POLICY_MASTER" = true ] && [ "$GAME_ACTIVE" = 1 ] && [ "$GAME_LOCK_ENABLE" = true ] && [ -n "$GAME_LOCK_LIST" ]; then
            do_lock "$GAME_LOCK_LIST"
            state="locked"
        else
            do_unlock
            state="unlocked"
        fi
        remove_freq_cap
        echo "$state|$(echo "$PKGS" | head -1)" > "$STATE_FILE"
    elif [ "$ENABLED" = "true" ] && [ -n "$LOCK_LIST" ] && [ "$SAFE_MODE" = "0" ] &&
        { [ "$THERMAL_HOT" != "1" ] || [ "$THERMAL_MODE" != "unlock" ]; }; then
        # 首次锁核崩溃保护：先写 CRASH_FLAG（当前 BOOT_ID），锁核完成后 20 秒内
        # 若进程被系统崩溃/强杀带走，下次开机 boot_id 相同 → 上面判定进安全模式。
        # 正常走完 20 秒则删标记，视为本次开机锁核安全。
        printf '%s\n' "$BOOT_ID" > "$CRASH_FLAG"
        do_lock
        if [ "$LIMIT_FREQ" = true ]; then apply_freq_cap; else remove_freq_cap; fi
        sleep 20
        rm -f "$CRASH_FLAG"
        state="locked"
        echo "locked|boot" > "$STATE_FILE"
        log "启动完成，日常模式：大核已封锁"
    elif [ "$ENABLED" = "true" ] && [ "$SAFE_MODE" = "0" ] && [ "$THERMAL_HOT" = "1" ] && [ "$THERMAL_MODE" = "unlock" ]; then
        do_unlock
        remove_freq_cap
        state="unlocked"
        echo "unlocked|boot" > "$STATE_FILE"
        log "启动完成，温度策略：恢复全部核心"
    elif [ "$SAFE_MODE" = "1" ]; then
        echo "safe|-" > "$STATE_FILE"
        log "启动完成（安全模式：未封锁任何核心）"
        state="safe"
    elif [ "$ENABLED" != "true" ]; then
        # 开机固态模式：sh 已关闭，不依赖轮询，直接按当前配置锁核与限频。
        # 与主循环固态模式分支同口径：手动恢复标记存在则保持核心在线。
        want_lock=yes
        if [ -f "$UNLOCK_HOLD" ]; then
            state="unlocked"
            echo "unlocked|manual" > "$STATE_FILE"
            log "sh 已关闭：开机检测到手动恢复标记，保持核心在线"
        else
            if [ "$(cfg_bool limit_freq false)" = "true" ]; then apply_freq_cap; fi
            do_lock
            state="locked"
            echo "locked|solid" > "$STATE_FILE"
            log "sh 已关闭：开机即以固态模式运行（按当前配置锁核与限频）"
        fi
    else
        echo "off|-" > "$STATE_FILE"
        log "启动完成（模块禁用或无可封锁核心）"
        state="off"
    fi

    _fast_n=0

    while :; do
        cfg_reload
        _FG_ROUND_READY=0
        _SCREEN_ROUND_READY=0
        # 自检：模块被删除 / 卸载中 / 被禁用 → 恢复全部并退出（保证无残留）
        if [ ! -f "$MODDIR/module.prop" ] || [ -f "$MODDIR/remove" ] || [ -f "$MODDIR/disable" ] || [ -f "/data/adb/modules/${MODULE_ID}.disable" ]; then
            log "检测到模块已删除/禁用，恢复全部核心并退出"
            cleanup_on_exit
        fi

        ENABLED=$(cfg_bool enabled true)
        # 刷新封锁名单（支持 App 运行时改核心）
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
        # poll_interval：检测间隔（秒），有效范围 5~600。
        # 非法值（空/非数字）一律回退默认 10 秒；不再有"0=自动跟随"的特殊语义。
        INTERVAL=$(cfg_int poll_interval 10)
        # game_poll_interval：游戏态轮询间隔（秒），有效范围 5~600，默认 30。
        # 与日常 poll_interval 分开：日常要省电、游戏要跟手，节奏需求相反。
        GAME_INTERVAL=$(cfg_int game_poll_interval 30)
        NO_CHARGE=$(cfg_bool no_lock_charging false)
        GAME_LIST=$(grep -v '^#' "$PACKAGES_FILE" 2>/dev/null | grep -v '^$')
        # 游戏锁核开关与名单必须每轮重读：App 运行时改开关/改名单要立即生效，无需重启模块。
        GAME_LOCK_ENABLE=$(cfg_bool game_lock_enable false)
        GAME_LOCK_LIST=$(cfg_val game_lock_cores "")
        GAME_LOCK_LIST=$(printf '%s' "$GAME_LOCK_LIST" | tr ',、' ' ' | tr -s ' ' | xargs)
        # 录屏 / 相机自动恢复：开关关闭则跳过检测；开启时优先读 capture.txt，读空/缺失用内置默认兜底
        CAPTURE_BOOST=$(cfg_bool capture_boost false)
        if [ "$(cfg_bool policy_master_enabled false)" = true ] && [ "$CAPTURE_BOOST" = true ] && [ "$ENABLED" = true ] && [ "$SAFE_MODE" != 1 ]; then
            CAPTURE_LIST=$(grep -v '^#' "$CAPTURE_FILE" 2>/dev/null | grep -v '^$')
            [ -z "$CAPTURE_LIST" ] && CAPTURE_LIST="$CAPTURE_DEFAULT"
        else
            CAPTURE_LIST=""
        fi

        case "$INTERVAL" in
            ''|*[!0-9]*) INTERVAL=10;;
        esac
        # 直接钳制到合法区间 5~600（不再有 0=自动 的特殊分支）
        [ "$INTERVAL" -lt 5 ] && INTERVAL=5
        [ "$INTERVAL" -gt 600 ] && INTERVAL=600
        case "$GAME_INTERVAL" in
            ''|*[!0-9]*) GAME_INTERVAL=30;;
        esac
        [ "$GAME_INTERVAL" -lt 5 ] && GAME_INTERVAL=5
        [ "$GAME_INTERVAL" -gt 600 ] && GAME_INTERVAL=600

        POLICY_MASTER=false
        strategy_enabled && POLICY_MASTER=true
        thermal_update

        # Freezing is independent of the CPU switch. Safety mode still restores it.
        if [ "$SAFE_MODE" = "1" ]; then
            freeze_restore_all
        else
            freeze_sync
        fi
        if [ "$ENABLED" != "true" ] || [ "$SAFE_MODE" = "1" ]; then
            thermal_publish
        fi

        # ---- 主开关 / 安全模式处理 ----
        # 【设计裁决（统一版合并主线）】ENABLED 与 SAFE_MODE 必须分开处理：
        #   · SAFE_MODE=1：崩溃自愈态，本次开机真正解锁全部核心，绝不能继续锁核；
        #   · ENABLED!=true：用户主动关掉「启用 sh 轮询进程」。这不是「禁用模块」，
        #     而是「不再轮询检测」——此时必须保持用户当前配置的锁核与限频（固态模式），
        #     否则用户关掉轮询反而更耗电，与产品语义相反，也与 daemon_revive 注释里
        #     「重建后仍按当前配置锁核与限频」自相矛盾。
        # 因此把原来的合并分支拆成两个独立分支。
        if [ "$SAFE_MODE" = "1" ]; then
            if [ "$state" != "safe" ]; then
                do_unlock
                restore_core_ctl
                remove_freq_cap
                last_pkg=""
                state="safe"
                echo "safe|-" > "$STATE_FILE"
                log "进入安全模式：核心全部恢复"
            fi
            sleep "$INTERVAL"
            continue
        fi

        if [ "$ENABLED" != "true" ]; then
            # ========== 固态模式：sh 轮询已关闭，但保持用户当前配置的锁核与限频 ==========
            # 手动恢复标记优先：用户刚点过「恢复全部核心」，保持核心在线，不再自动锁回。
            if [ -f "$UNLOCK_HOLD" ]; then
                if [ "$state" != "unlocked" ]; then
                    last_pkg=""
                    state="unlocked"
                    echo "unlocked|manual" > "$STATE_FILE"
                fi
                thermal_publish
                log "固态模式：检测到手动恢复标记，保持核心在线（不再自动锁回）"
                sleep "$INTERVAL"
                continue
            fi
            # 无手动恢复标记：按配置施加限频，并保持锁核。
            if [ "$LIMIT_FREQ" = "true" ]; then
                apply_freq_cap
            fi
            if [ "$state" != "locked" ]; then
                do_lock
                last_pkg=""
                state="locked"
                echo "locked|solid" > "$STATE_FILE"
                log "sh 已关闭：进入固态模式，保持当前锁核与限频"
            fi
            thermal_publish
            sleep "$INTERVAL"
            continue
        fi

        # ---- 记录上一轮是否为游戏模式（必须在 state 被改写前判断，供间隔逻辑使用） ----
        prev_unlocked=0
        [ "$state" = "unlocked" ] && prev_unlocked=1

        # Baseline screen/foreground/game polling is independent of optional strategies.
        _fast_n=0
        [ "$_SCREEN_ROUND_READY" = 1 ] || ss=$(screen_sysfs)
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
            scan_publish screen_off
        else
            fg_refresh
        fi
        pkg=$(echo "$PKGS" | head -1)

        # ---- 决策：是否封锁（息屏一律锁定） ----
        want_lock=yes
        # 游戏 / 录屏 / 相机：命中即进入「性能/游戏」分支。
        # 游戏若开了「游戏保持锁核」，不再全部解封，改为按游戏名单主动锁核。
        GAME_ACTIVE=0
        GAME_LOCKING=0
        if [ "$ss" != "OFF" ]; then
            if [ -n "$GAME_LIST" ] && is_game "$PKGS"; then
                GAME_ACTIVE=1
                want_lock=no
                # 双向切换：游戏锁核开启且名单非空 → 游戏态主动锁名单内的核
                if [ "$POLICY_MASTER" = true ] && [ "$GAME_LOCK_ENABLE" = true ] && [ -n "$GAME_LOCK_LIST" ]; then
                    GAME_LOCKING=1
                fi
            fi
            [ "$POLICY_MASTER" = true ] && [ "$CAPTURE_BOOST" = true ] && [ "$want_lock" = yes ] && [ -n "$CAPTURE_LIST" ] && is_capture "$PKGS" && want_lock=no
        fi
        # 充电时不封锁
        if [ "$POLICY_MASTER" = "true" ] && [ "$want_lock" = "yes" ] && [ "$NO_CHARGE" = "true" ] && is_charging; then
            want_lock=no
        fi

        # 高温解封保持原行为；高温额外锁核仅叠加于日常锁核，游戏优先。
        thermal_decide

        # ---- 执行 ----
        if [ "$want_lock" = "yes" ]; then
            # ==== v2.5.6 修正：日常轮询也要尊重「刚刚的手动恢复」 ====
            # 场景：用户在 App 点「恢复全部核心」，宽限期内又点了一下刷新，
            # 若这里立刻 do_lock，用户看到的就是「恢复了又马上锁回去」。
            # 宽限期（HOLD_GRACE 秒）过后本函数返回假，轮询自动接管省电，
            # 既保证手动操作看得见效果，也不让一次手动恢复永久废掉省电。
            if unlock_hold_active; then
                if [ "$state" != "unlocked" ]; then
                    state="unlocked"
                    last_pkg=""
                    echo "unlocked|manual" > "$STATE_FILE"
                    thermal_publish
                    log "检测到手动恢复标记：本轮跳过自动锁核（宽限 ${HOLD_GRACE}s）"
                fi
                sleep "$INTERVAL"
                continue
            fi
            state_changed=0
            [ "$state" != "locked" ] && state_changed=1
            if [ "$state_changed" = "1" ]; then
                log "切换为日常模式：封锁大核（前台: $pkg）"
            fi
            do_lock
            if [ "$LIMIT_FREQ" = "true" ]; then
                apply_freq_cap
            else
                # 限频开关为关：主动确保任何残留的限频锁定都被解除。
                # （旧代码在 locked 分支只调 apply_freq_cap，被其内部守卫挡住后
                #   永远没机会调 remove_freq_cap，导致"关闭限频后仍被限速"。）
                remove_freq_cap
            fi
            # 仅在状态切换时打印封锁结果，避免每轮刷爆日志
            if [ "$state_changed" = "1" ]; then
                oc_now=$(online_count)
                log "封锁结果：[${LOCK_STATE}] 当前在线核心 ${oc_now} 个"
            fi
            state="locked"
            if [ "$last_pkg" != "$pkg" ] || [ "$(cat "$STATE_FILE" 2>/dev/null)" != "$state|$pkg" ]; then
                last_pkg="$pkg"
                echo "locked|$pkg" > "$STATE_FILE"
            fi
        else
            if [ "$GAME_LOCKING" = "1" ]; then
                # ---- 游戏保持锁核（双向切换）：勾了哪个锁哪个，没勾的解封 ----
                if [ "$state" != "gamelock" ]; then
                    log "游戏锁核生效：只锁名单 [$GAME_LOCK_LIST]（前台: $pkg）"
                fi
                do_lock "$GAME_LOCK_LIST"
                remove_freq_cap
                state="gamelock"
                _tag="|game"
                if [ "$last_pkg" != "$pkg" ] || [ "$(cat "$STATE_FILE" 2>/dev/null)" != "$state|$pkg$_tag" ]; then
                    last_pkg="$pkg"
                    echo "$state|$pkg$_tag" > "$STATE_FILE"
                fi
            else
                # V2.4.1：没开「游戏锁核」或名单为空时，进游戏就是全解——
                # 主页手动封锁的核在这里也一并放开，游戏期间只认 game_lock_cores。
                # 退出游戏回到日常后，无参 do_lock 会把主页手动名单重新锁回去。
                if [ "$state" != "unlocked" ]; then
                    log "切换为性能模式：恢复全部核心（前台: $pkg）"
                fi
                do_unlock
                remove_freq_cap
                if [ -z "$UNLOCK_FAILED" ]; then state="unlocked"; else state="unlock_partial"; fi
                # 第四段标记 game 仅用于 APK 区分「游戏释放」与「用户手动解封」：
                # 旧版读取时整行按 | 切分只取前两段，多一段不影响兼容。
                _tag=""
                [ "$GAME_ACTIVE" = 1 ] && _tag="|game"
                if [ "$last_pkg" != "$pkg" ] || [ "$(cat "$STATE_FILE" 2>/dev/null)" != "$state|$pkg$_tag" ]; then
                    last_pkg="$pkg"
                    echo "$state|$pkg$_tag" > "$STATE_FILE"
                fi
            fi
        fi

        # ---- 间隔：日常按 poll_interval，游戏态按 game_poll_interval ----
        # 只有"刚退出游戏 / 刚进入游戏"的过渡轮用 5 秒短间隔，让锁核状态尽快对齐；
        # 稳态（日常 / 息屏）按 INTERVAL 走，游戏进行中按 GAME_INTERVAL 走。
        # V2.3.6：加入游戏进出翻转检测——退出游戏的当轮必须立刻重新施加日常锁核，
        # 否则会白等满一个 GAME_INTERVAL 才有核心被锁。
        if [ "$GAME_ACTIVE" != "$prev_game" ]; then
            prev_game="$GAME_ACTIVE"
            sleep 5                     # 刚进入 / 刚退出游戏：快速对齐一轮
        elif [ "$GAME_ACTIVE" = "1" ]; then
            sleep "$GAME_INTERVAL"      # 仅真实游戏态使用游戏间隔
        elif [ "$state" = "locked" ] && { [ "$prev_unlocked" = "1" ] || [ "$state_changed" = "1" ]; }; then
            sleep 5                     # 刚封锁完成的过渡轮：快速确认一次
        else
            sleep "$INTERVAL"           # 日常 / 息屏稳态：完整按用户配置间隔
        fi
    done
}