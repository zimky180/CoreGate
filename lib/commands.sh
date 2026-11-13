# ================================================================
#  命令入口
# ================================================================
# 用法：
#   service.sh                  → 进入常驻守护循环（默认，开机由 KSU 调用）
#   service.sh --lock-once      → 只执行一次「立即封锁」，不进入守护循环
#   service.sh --unlock-once    → 只执行一次「立即恢复全部核心 + 撤销限频」
#   service.sh --lock-once N    → 同上，并用 N 作为封锁核心数（1~4，覆盖配置）
#
# 说明：早期版本无参数解析，任何参数都会被忽略并直接进入守护循环，
#       导致 APK 的「立即封锁」按钮形同虚设（永远走 sysfs 兜底、count 参数无效）。
#       现改为在进入循环前先解析参数，一次性命令执行完立即退出，不驻留。
# ================================================================
lock_once() {
    AUTO_COUNT=$(cfg_int auto_lock_count 1)
    # 一次性封锁：加载当前配置 → 封锁 → 视限频开关决定是否限频 → 退出
    # 注意：不写 PID、不进循环、不装 trap（避免退出时把用户刚锁好的核又全部解开）
    ENABLED=$(cfg_bool enabled true)
    # 在 detect_high 前确定数量，确保临时参数也能扩大自动候选名单。
    case "$1" in
        ''|*[!0-9]*) : ;;
        *) AUTO_COUNT="$1"; [ "$AUTO_COUNT" -lt 1 ] && AUTO_COUNT=1;
           [ "$AUTO_COUNT" -gt 4 ] && AUTO_COUNT=4 ;;
    esac
    LOCK_LIST=$(cfg_val lock_cores auto)
    if [ "$LOCK_LIST" = "auto" ]; then
        LOCK_LIST=$(detect_high)
    else
        LOCK_LIST=$(echo "$LOCK_LIST" | tr ',、' ' ' | tr -s ' ')
    fi
    # 可选参数 $1：临时封锁核心数（1~4），仅本次生效、不写回配置
    if [ -n "$1" ]; then
        case "$1" in
            ''|*[!0-9]*) : ;;   # 非数字忽略
            *)
                n="$AUTO_COUNT"
                # 取名单里靠后的 n 个核心（detect_high 默认把最高频核放最后）
                LOCK_LIST=$(echo "$LOCK_LIST" | tr ' ' '\n' | grep -E '^[0-9]+$' | grep -v '^0$' | sort -nr | head -n "$n" | tr '\n' ' ')
                ;;
        esac
    fi
    DISABLE_CC=$(cfg_bool disable_core_ctl false)
    LIMIT_FREQ=$(cfg_bool limit_freq false)

    if [ "$ENABLED" != "true" ]; then
        echo "LOCK_ONCE: 模块已禁用，跳过封锁"
        exit 0
    fi
    if [ -z "$LOCK_LIST" ]; then
        echo "LOCK_ONCE: 无可封锁核心"
        exit 0
    fi

    do_lock
    # ==== v2.5.6：用户主动封锁 = 撤销「手动恢复意图」 ====
    # 不清标记的话，固态模式下主循环会一直认为「用户要核心在线」，永不重锁。
    rm -f "$UNLOCK_HOLD" 2>/dev/null
    if [ "$LIMIT_FREQ" = "true" ]; then
        apply_freq_cap
    else
        remove_freq_cap
    fi
    oc=$(online_count)
    echo "LOCK_ONCE_DONE: 名单=[$LOCK_LIST] 结果=[${LOCK_STATE}] 在线=${oc}"
    exit 0
}

unlock_once() {
    # 一次性恢复：清除手动封锁意图，解锁全部核心并撤销限频。
    manual_clear
    # ==== v2.5.6：落「手动恢复意图」标记 ====
    # 一次性命令是独立进程，写不进守护进程内存里的 state，
    # 主循环下一轮会照旧 do_lock，用户看到「恢复了又立刻变回去」。
    # 落时间戳标记后：enabled=true 时主循环宽限 HOLD_GRACE 秒不锁核，
    # enabled=false（固态模式）时永久尊重，直到用户再次手动封锁。
    date +%s > "$UNLOCK_HOLD" 2>/dev/null
    LOCK_LIST=$(cfg_val lock_cores auto)
    if [ "$LOCK_LIST" = "auto" ]; then
        LOCK_LIST=$(detect_high)
    else
        LOCK_LIST=$(echo "$LOCK_LIST" | tr ',、' ' ' | tr -s ' ')
    fi
    do_unlock
    remove_freq_cap
    oc=$(online_count)
    if [ -n "$UNLOCK_FAILED" ]; then
        echo "UNLOCK_ONCE_FAILED: 在线=${oc} 仍离线=[$UNLOCK_FAILED]"
        exit 1
    fi
    echo "UNLOCK_ONCE_DONE: 在线=${oc}"
    echo "OK"
    exit 0
}

case "$1" in
    --lock-once)
        shift
        lock_once "$1"
        ;;
    --unlock-once)
        unlock_once
        ;;
    --core-off)
        # App 点单个核心 = 要求它一直保持离线。
        # 只写清单 + 立刻下一次线，剩下的交给主循环维持：
        # 日常模式维持手动清单；启用游戏保持锁核时合并游戏策略名单。
        # 退出游戏由日常模式接管；录屏与相机恢复按场景策略执行。
        shift
        _c="$1"
        case "$_c" in ''|*[!0-9]*) echo "BADCPU"; exit 1;; esac
        core_guard_enter || { echo "FAIL"; exit 1; }
        if manual_add "$_c"; then
            # ==== v2.5.6：手动下核 = 撤销「手动恢复意图」 ====
            # 否则固态模式下主循环会一直跳过 do_lock，用户点的核下一轮就被拉回来。
            rm -f "$UNLOCK_HOLD" 2>/dev/null
            AUTO_COUNT=$(cfg_int auto_lock_count 1)
            LOCK_LIST=$(cfg_val lock_cores auto)
            if [ "$LOCK_LIST" = auto ]; then LOCK_LIST=$(detect_high); fi
            LOCK_LIST=$(printf '%s' "$LOCK_LIST" | tr ',、' ' ')
            DISABLE_CC=$(cfg_bool disable_core_ctl false)
            do_lock
            if cpu_online "$_c"; then
                manual_del "$_c"
                echo "FAIL"
            else
                echo "OK"
            fi
        else
            echo "FAIL"
        fi
        core_guard_leave
        ;;
    --core-on)
        # App 点同一个核心 = 撤销手动离线，交回自动策略。
        shift
        _c="$1"
        case "$_c" in ''|*[!0-9]*) echo "BADCPU"; exit 1;; esac
        core_guard_enter || { echo "FAIL"; exit 1; }
        manual_del "$_c"
        # 立刻拉回来，不等下一轮循环（用户点了就该马上看到变化）
        if [ -f "/sys/devices/system/cpu/cpu$_c/online" ]; then
            [ "$_c" = "0" ] || echo 1 > "/sys/devices/system/cpu/cpu$_c/online" 2>/dev/null
        fi
        if cpu_online "$_c"; then echo "OK"; else echo "FAIL"; fi
        core_guard_leave
        ;;
    --core-clear)
        # 「恢复全部核心」按钮：清空手动清单，再走一遍标准恢复。
        manual_clear
        unlock_once
        ;;
    --core-list)
        # 只读：输出当前手动离线的核号，空格分隔，便于 App 与在线状态对照。
        manual_list | tr '\n' ' '
        echo ""
        ;;
    --freeze-status)
        # 只读查询：给 App 状态面板用。输出分两段，便于前端一眼分清
        #「本模块冻结了什么」和「系统当前实际是什么状态」（后者才是是否真生效的证据）。
        #
        # [applied] 本模块记录在案的冻结项：包名<TAB>方式
        # [actual]  系统当前真实的停用/挂起列表：包名<TAB>方式（含非本模块所为）
        _status_actual=$(freeze_status_report)
        echo "[applied]"
        if [ -f "$FREEZE_STATE" ] && [ -s "$FREEZE_STATE" ]; then
            while IFS='	' read -r _p _st _md; do
                [ -z "$_p" ] && continue
                [ -z "$_md" ] && _md="disable"
                printf '%s\t%s\n' "$_p" "$_md"
            done < "$FREEZE_STATE"
        else
            # 记录文件不存在或为空（freeze_restore_all 结尾会 rm 掉它，模块升级也可能丢）：
            # 用「组开关为 on 且组内包在系统里确实被停用/挂起」反推，
            # 免得界面把已经冻上的包报成「没有冻结」。只补真实出现在 actual 里的包。
            _fb_actual=$(printf '%s\n' "$_status_actual" | cut -f1)
            echo "$FREEZE_TABLE" | while IFS= read -r _fb_line; do
                [ -z "$_fb_line" ] && continue
                _fb_key=$(printf %s "$_fb_line" | cut -d"|" -f1)
                freeze_group_on "$_fb_key" || continue
                for _fb_p in $(freeze_group_pkgs "$_fb_key"); do
                    [ -z "$_fb_p" ] && continue
                    echo "$_fb_actual" | grep -qxF "$_fb_p" || continue
                    printf "%s\t%s\n" "$_fb_p" "disable"
                done
            done
        fi
        echo "[actual]"
        printf '%s\n' "$_status_actual"
        echo "[groups]"
        # 各组开关当前值，供界面回显
        echo "$FREEZE_TABLE" | while IFS= read -r _line; do
            [ -z "$_line" ] && continue
            _k=$(printf %s "$_line" | cut -d"|" -f1)
            if freeze_group_on "$_k"; then echo "$_k	on"; else echo "$_k	off"; fi
        done
        exit 0
        ;;
    --set-freeze)
        # 单个组开关：--set-freeze grp_log true|false
        # 只改 config.json，具体冻结/恢复交给 --freeze-sync 或守护循环执行。
        _k="$2"
        _v="$3"
        if [ -z "$_k" ]; then echo "SET_FREEZE_FAIL: 缺组键"; exit 1; fi
        # 组键归一化：APK 侧 FreezeData.GROUPS 的 key 是短名（log/media/diag...），
        # 而 config 里的键与 FREEZE_TABLE 第一列都是 grp_ 前缀（freeze_grp_log）。
        # 若不补前缀，短名会被写成 freeze_diag 这种孤儿键：
        #     · freeze_group_on 只认 freeze_grp_diag → 开关永远不生效
        #     · 而且返回 SET_FREEZE_OK，界面显示成功、实际什么都没冻
        # 这里两种写法都接受，统一归一到 grp_ 前缀。
        case "$_k" in
            grp_*) ;;
            *) _k="grp_$_k" ;;
        esac
        # 校验组键真实存在，避免界面传错键名时静默堆积垃圾键
        _kknown=""
        _kchk=$(echo "$FREEZE_TABLE" | while IFS= read -r _kl; do
            [ -z "$_kl" ] && continue
            [ "$(printf %s "$_kl" | cut -d"|" -f1)" = "$_k" ] && echo yes && break
        done)
        [ "$_kchk" = "yes" ] && _kknown=1
        if [ -z "$_kknown" ]; then
            echo "SET_FREEZE_FAIL: 未知组键 $_k"
            exit 1
        fi
        case "$_v" in
            true|false) ;;
            *) echo "SET_FREEZE_FAIL: 值须为 true 或 false"; exit 1 ;;
        esac
        freeze_lock || { echo SET_FREEZE_BUSY; exit 1; }
        cfg_set_bool "freeze_$_k" "$_v" || { freeze_unlock; echo "SET_FREEZE_FAIL: 写配置失败"; exit 1; }
        # 组被打开/关闭立刻同步一次，用户点完就能看到效果，不用等下个轮询周期
        for _fm_member in $(freeze_group_pkgs "$_k"); do freeze_manual_del "$_fm_member"; done
        _requested_group="$_k"; _requested_value="$_v"
        _group_result=0
        for _group_pkg in $(freeze_group_pkgs "$_requested_group"); do
            pkg_exists "$_group_pkg" || continue
            if [ "$_requested_value" = true ] ||
               [ -n "$(freeze_pkg_used_by_other "$_group_pkg" "$_requested_group")" ]; then
                freeze_off_pkg "$_group_pkg" || _group_result=1
            else
                freeze_manual_set "$_group_pkg" false || _group_result=1
                freeze_on_pkg "$_group_pkg" true || _group_result=1
            fi
        done
        freeze_unlock
        if [ "$_group_result" != 0 ]; then echo "SET_FREEZE_PARTIAL: $_requested_group=$_requested_value"; exit 1; fi
        echo "SET_FREEZE_OK: $_requested_group=$_requested_value"
        exit 0
        ;;
    --freeze-add|--freeze-del)
        _action="$1"; _requested_pkg="$2"
        case "$_requested_pkg" in ''|*[!a-zA-Z0-9_.]*) echo FREEZE_FAIL; exit 1;; esac
        # Only explicit table entries are accepted.
        _known_pkgs=$(printf '%s\n' "$FREEZE_TABLE" | cut -d'|' -f3 | tr ' ' '\n')
        printf '%s\n' "$_known_pkgs" | grep -qxF "$_requested_pkg" || { echo FREEZE_FAIL; exit 1; }
        freeze_lock || { echo FREEZE_BUSY; exit 1; }
        _action_ok=1
        if [ "$_action" = --freeze-add ]; then
            # Persist intent first so a transient failure is retried by the daemon.
            freeze_manual_set "$_requested_pkg" true &&
                freeze_off_pkg "$_requested_pkg" && pkg_is_disabled "$_requested_pkg" && _action_ok=0
            _action_mark=FREEZE_ADD
        else
            if freeze_manual_set "$_requested_pkg" false; then
                freeze_on_pkg "$_requested_pkg" true && _action_ok=0
            fi
            _action_mark=FREEZE_DEL
        fi
        freeze_unlock
        if [ "$_action_ok" = 0 ]; then echo "${_action_mark}_OK: $_requested_pkg"; else echo "${_action_mark}_FAIL: $_requested_pkg"; fi
        exit "$_action_ok"
        ;;
    --freeze-sync)
        # 按当前 config.json 立即同步一次组开关状态（不进入守护循环）
        freeze_sync || { echo "FREEZE_SYNC_FAIL"; exit 1; }
        echo "FREEZE_SYNC_DONE"
        exit 0
        ;;
    --daemon-revive)
        echo "CORE_GATE_STOPPED: restart device to resume"
        exit 1
        ;;
    --stop)
        _stop_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
        [ -n "$_stop_boot" ] || { echo STOP_FAIL; exit 1; }
        # Persist before signalling so no concurrent launch can undo this stop.
        printf '%s\n' "$_stop_boot" > "$CONFIG_DIR/stopped.boot" || exit 1
        cfg_set_bool enabled false || { echo STOP_FAIL; exit 1; }
        _stop_pid=$(cat "$PID_FILE" 2>/dev/null)
        case "$_stop_pid" in ''|*[!0-9]*|0|1) ;; *)
            _stop_cmd=$(tr '\000' ' ' < "/proc/$_stop_pid/cmdline" 2>/dev/null)
            case "$_stop_cmd" in *"$MODDIR/CoreGate.sh"*|*"$MODDIR/service.sh"*)
                if [ "$_stop_pid" != "$$" ] && kill -0 "$_stop_pid" 2>/dev/null; then
                    kill -TERM "$_stop_pid" 2>/dev/null || { echo STOP_FAIL; exit 1; }
                    _stop_wait=0
                    while kill -0 "$_stop_pid" 2>/dev/null && [ "$_stop_wait" -lt 10 ]; do
                        sleep 1
                        _stop_wait=$((_stop_wait + 1))
                    done
                    kill -0 "$_stop_pid" 2>/dev/null && { echo STOP_FAIL; exit 1; }
                fi
                ;; *) echo STOP_PID_MISMATCH; exit 1;; esac
            ;;
        esac
        rm -f "$PID_FILE"
        cfg_set_bool daemon_alive false || { echo STOP_FAIL; exit 1; }
        echo "dead" > "$STATE_FILE"
        echo STOP_OK
        exit 0
        ;;
    --freeze-restore)
        # 一键全部恢复：把本模块停用过的组件全部启用
        freeze_clear_policy_and_restore || { echo "FREEZE_RESTORE_FAIL"; exit 1; }
        echo "FREEZE_RESTORE_DONE"
        exit 0
        ;;
    *)
        run
        ;;
esac
