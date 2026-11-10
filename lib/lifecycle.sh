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
    if [ -f "$MODDIR/module.prop" ] && [ ! -f "$MODDIR/remove" ] && [ ! -f "$MODDIR/disable" ]; then
        restore_all preserve
    else
        restore_all
    fi
    rm -f "$PID_FILE" "$CONFIG_DIR/crash_flag"
    log "模块服务已退出，全部恢复原始状态"
    exit 0
}
trap cleanup_on_exit TERM INT EXIT

run() {
    # 进入守护主循环：此后退出（TERM/INT/EXIT）才需要全量还原，武装 trap。
    TRAP_ARMED=1
    freeze_wait_pms
    echo $$ > "$PID_FILE" 2>/dev/null
    rm -f "$CONFIG_DIR/high_cores"
    state=""; pkg=""; want_lock=""; last_pkg=""; lock_logged=0; ss=""; it2=0; last_ss=""
    prev_unlocked=0; oc_now=""
    prev_game=0

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
    BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    if [ -n "$BOOT_ID" ] && [ "$(cat "$CRASH_FLAG" 2>/dev/null)" = "$BOOT_ID" ]; then
        SAFE_MODE=1
        log "⚠️ 检测到上次异常退出标记，进入【安全模式】：本次不封锁任何核心（重启一次后自动恢复）"
    else
        SAFE_MODE=0
    fi
    rm -f "$CRASH_FLAG" 2>/dev/null
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

    # 首次应用（安全模式下不锁核；锁核前预置崩溃标记，20 秒系统正常后解除）
    ENABLED=$(cfg_bool enabled true)
    thermal_update
    GAME_LIST=$(grep -v '^#' "$PACKAGES_FILE" 2>/dev/null | grep -v '^$')
    GAME_ACTIVE=0
    # 游戏锁核：进游戏时只把 game_lock_cores 名单内的核心保持离线，其余上线。
    GAME_LOCK_ENABLE=$(cfg_bool game_lock_enable false)
    GAME_LOCK_LIST=$(cfg_val game_lock_cores "")
    GAME_LOCK_LIST=$(printf '%s' "$GAME_LOCK_LIST" | tr ',、' ' ' | tr -s ' ' | xargs)
    PKGS=$(fg_pkgs)
    if [ -n "$GAME_LIST" ] && is_game "$PKGS"; then GAME_ACTIVE=1; fi
    want_lock=yes
    [ "$GAME_ACTIVE" = 1 ] && want_lock=no
    CAPTURE_BOOST=$(cfg_bool capture_boost false)
    CAPTURE_LIST=""
    if [ "$CAPTURE_BOOST" = true ]; then
        CAPTURE_LIST=$(grep -v '^#' "$CAPTURE_FILE" 2>/dev/null | grep -v '^$')
        [ -n "$CAPTURE_LIST" ] || CAPTURE_LIST="$CAPTURE_DEFAULT"
        [ -n "$CAPTURE_LIST" ] && is_capture "$PKGS" && want_lock=no
    fi
    NO_CHARGE=$(cfg_bool no_lock_charging false)
    [ "$NO_CHARGE" = true ] && is_charging && want_lock=no
    thermal_decide
    if [ "$want_lock" = no ] && [ "$ENABLED" = true ] && [ "$SAFE_MODE" = 0 ]; then
        _boot_keep=""
        if [ "$GAME_ACTIVE" = 1 ] && [ "$GAME_LOCK_ENABLE" = true ] && [ -n "$GAME_LOCK_LIST" ]; then
            _boot_keep="$GAME_LOCK_LIST"
        fi
        do_unlock "$_boot_keep"
        remove_freq_cap
        state="unlocked"
        echo "unlocked|$(echo "$PKGS" | head -1)" > "$STATE_FILE"
    elif [ "$ENABLED" = "true" ] && [ -n "$LOCK_LIST" ] && [ "$SAFE_MODE" = "0" ] &&
        { [ "$THERMAL_HOT" != "1" ] || [ "$THERMAL_MODE" != "unlock" ]; }; then
        printf '%s\n' "$BOOT_ID" > "$CRASH_FLAG"
        do_lock
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
    else
        echo "off|-" > "$STATE_FILE"
        log "启动完成（模块禁用或无可封锁核心）"
        state="off"
    fi

    _fast_n=0

    while :; do
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
        if [ "$CAPTURE_BOOST" = "true" ]; then
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

        # ---- 主开关 / 安全模式：关闭则全部恢复 ----
        if [ "$ENABLED" != "true" ] || [ "$SAFE_MODE" = "1" ]; then
            if [ "$state" != "off" ] && [ "$state" != "safe" ]; then
                do_unlock
                restore_core_ctl
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

        # ---- 低功耗快速通道 ----
        # 目的：do_lock/do_unlock 每轮都要拉起一堆子进程（core_guard_enter、
        # restore_core_ctl、逐核 set_cpu + sleep 1、每核 3 遍 core_restore_except），
        # 即使目标态早已达成也照跑一遍，这是后台最大的无谓耗电点。
        # 判据：所有策略位都不活跃 + 上一轮已是 locked → 目标态本来就是「锁核」，
        # 且没有任何策略能让它变，于是跳过整轮检测，直接长睡。
        # 注意：无法判定的情况（未知屏幕态/首次运行）一律走正常流程，宁可多跑不漏跑。
        # 前置条件：温度策略开启时必须本机有可用的温度读数（电池温度）。
        # 若连电池温度都读不到（unavailable），高温解封无法判断，必须每轮完整检测，
        # 否则核心被锁死而温度无从判断，属于功能性风险，不做快速跳过。
        # 温度策略关闭时 thermal_update 已短路、THERMAL_TEMP 恒为空，
        # 此时不存在「按温度解封」的需求，快速通道可直接放行，不因此失效。
        _fast_cpu_ok=0
        if [ "$(cfg_bool temperature_enabled false)" != "true" ]; then
            _fast_cpu_ok=1
        else
            [ -n "$THERMAL_TEMP" ] && _fast_cpu_ok=1
        fi
        _pam=$(policy_active_mask)
        if [ "$_fast_cpu_ok" = "1" ] && [ -z "$_pam" ] && [ "$state" = "locked" ]; then
            # 核心被系统或第三方强行拉回在线时，允许最多 3 轮后强制走一次完整 do_lock 纠正
            _fast_n=$(( _fast_n + 1 ))
            if [ "$_fast_n" -lt 3 ]; then
                ss=$(screen_sysfs)
                if [ "$ss" = "OFF" ]; then
                    sleep "$INTERVAL"
                    continue
                fi
                if [ "$ss" = "ON" ]; then
                    PKGS=$(fg_pkgs)
                    pkg=$(echo "$PKGS" | head -1)
                    if [ "$last_pkg" != "$pkg" ]; then
                        last_pkg="$pkg"
                        echo "locked|$pkg" > "$STATE_FILE"
                    fi
                    sleep "$INTERVAL"
                    continue
                fi
                # 屏幕态未知：不冒险，落回完整流程
            fi
        fi
        _fast_n=0
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
        # 游戏 / 录屏 / 相机：命中即进入「性能/游戏」分支。
        # 游戏若开了「游戏保持锁核」，不再全部解封，改为按游戏名单主动锁核。
        GAME_ACTIVE=0
        GAME_LOCKING=0
        if [ "$ss" != "OFF" ]; then
            if [ -n "$GAME_LIST" ] && is_game "$PKGS"; then
                GAME_ACTIVE=1
                want_lock=no
                # 双向切换：游戏锁核开启且名单非空 → 游戏态主动锁名单内的核
                if [ "$GAME_LOCK_ENABLE" = "true" ] && [ -n "$GAME_LOCK_LIST" ]; then
                    GAME_LOCKING=1
                fi
            fi
            [ "$want_lock" = "yes" ] && [ -n "$CAPTURE_LIST" ] && is_capture "$PKGS" && want_lock=no
        fi
        # 充电时不封锁
        if [ "$want_lock" = "yes" ] && [ "$NO_CHARGE" = "true" ] && is_charging; then
            want_lock=no
        fi

        # 高温解封保持原行为；高温额外锁核仅叠加于日常锁核，游戏优先。
        thermal_decide

        # ---- 执行 ----
        if [ "$want_lock" = "yes" ]; then
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
        elif [ "$state" != "locked" ]; then
            sleep "$GAME_INTERVAL"      # 游戏模式：按游戏间隔
        elif [ "$prev_unlocked" = "1" ] || [ "$state_changed" = "1" ]; then
            sleep 5                     # 刚封锁完成的过渡轮：快速确认一次
        else
            sleep "$INTERVAL"           # 日常 / 息屏稳态：完整按用户配置间隔
        fi
    done
}