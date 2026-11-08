# ---------------- 温度策略（仅读取传感器，不改系统温控） ----------------
THERMAL_HOT=0
THERMAL_KEY=""
THERMAL_EXTRA_ACTIVE=""
THERMAL_TEMP=""
THERMAL_STATE_FILE="$CONFIG_DIR/temperature.state"

thermal_read() {
    # Android 电池节点单位为 0.1℃；统一输出毫摄氏度，不用 CPU 热点替代。
    _battery_temp=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
    case "$_battery_temp" in ''|*[!0-9-]*) _battery_temp="";; esac
    if [ -n "$_battery_temp" ] && [ "$_battery_temp" -ge -200 ] 2>/dev/null && [ "$_battery_temp" -le 1000 ]; then
        echo "$((_battery_temp * 100))"
        return
    fi
    dumpsys battery 2>/dev/null | awk '/^[[:space:]]*temperature:/ {
        if ($2 ~ /^-?[0-9]+$/ && $2 >= -200 && $2 <= 1000) printf "%.0f\n", $2 * 100;
        exit
    }'
}

thermal_publish() {
    printf '%s|%s|%s|%s|%s|battery|%s|%s\n' "$_thermal_status" "$THERMAL_TEMP" "$THERMAL_MODE" "$THERMAL_THRESHOLD" "$(date +%s)" "$THERMAL_EXTRA_CONFIG" "$THERMAL_EXTRA_ACTIVE" > "$THERMAL_STATE_FILE.$$.tmp" &&
        mv -f "$THERMAL_STATE_FILE.$$.tmp" "$THERMAL_STATE_FILE"
}

thermal_select_extra() {
    THERMAL_EXTRA_ACTIVE=""
    _extra_raw=$(printf '%s' "$THERMAL_EXTRA_CONFIG" | tr ',、' ' ')
    for _extra_cpu in $_extra_raw; do
        case "$_extra_cpu" in ''|0|*[!0-9]*) continue;; esac
        [ -d "/sys/devices/system/cpu/cpu$_extra_cpu" ] || continue
        case " $THERMAL_EXTRA_ACTIVE " in *" $_extra_cpu "*) continue;; esac
        THERMAL_EXTRA_ACTIVE="$THERMAL_EXTRA_ACTIVE $_extra_cpu"
    done
}

thermal_decide() {
    THERMAL_EXTRA_ACTIVE=""
    if [ "$THERMAL_MODE" = lock ] && [ "$GAME_ACTIVE" = 1 ]; then
        # 游戏恢复优先，退出游戏后重新判断温度；不沿用游戏期间的滞回状态。
        THERMAL_HOT=0
        [ "$THERMAL_ENABLED" = true ] && [ "$ENABLED" = true ] && [ "$SAFE_MODE" != 1 ] && _thermal_status=game_skipped
    elif [ "$THERMAL_HOT" = 1 ]; then
        if [ "$THERMAL_MODE" = unlock ]; then
            want_lock=no
        elif [ "$want_lock" = yes ]; then
            thermal_select_extra
            [ -n "$THERMAL_EXTRA_ACTIVE" ] || _thermal_status=no_extra
        else
            _thermal_status=scene_skipped
        fi
    fi
    thermal_publish
}

thermal_update() {
    THERMAL_ENABLED=$(cfg_bool temperature_enabled false)
    THERMAL_MODE=$(cfg_val temperature_mode lock)
    [ "$THERMAL_MODE" = "unlock" ] || THERMAL_MODE=lock
    THERMAL_THRESHOLD=$(cfg_int temperature_threshold 40)
    case "$THERMAL_THRESHOLD" in ''|*[!0-9]*) THERMAL_THRESHOLD=40;; esac
    [ "$THERMAL_THRESHOLD" -lt 35 ] && THERMAL_THRESHOLD=35
    [ "$THERMAL_THRESHOLD" -gt 60 ] && THERMAL_THRESHOLD=60
    THERMAL_EXTRA_CONFIG=$(cfg_val temperature_lock_cores "")
    THERMAL_EXTRA_ACTIVE=""
    _tk="$THERMAL_ENABLED|$THERMAL_MODE|$THERMAL_THRESHOLD|$THERMAL_EXTRA_CONFIG|$ENABLED|$SAFE_MODE"
    if [ "$THERMAL_KEY" != "$_tk" ]; then THERMAL_HOT=0; THERMAL_KEY="$_tk"; fi
    _old_hot="$THERMAL_HOT"
    THERMAL_TEMP=""
    _thermal_status=disabled
    if [ "$THERMAL_ENABLED" = "true" ] && [ "$ENABLED" = "true" ] && [ "$SAFE_MODE" != "1" ]; then
        THERMAL_TEMP=$(thermal_read)
        if [ -z "$THERMAL_TEMP" ]; then
            # 电池温度不可用时撤销温度策略，回到普通策略。
            THERMAL_HOT=0; _thermal_status=unavailable
        else
            if [ "$THERMAL_TEMP" -ge "$((THERMAL_THRESHOLD * 1000))" ]; then
                THERMAL_HOT=1
            elif [ "$THERMAL_TEMP" -le "$(((THERMAL_THRESHOLD - 3) * 1000))" ]; then
                THERMAL_HOT=0
            fi
            _thermal_status=watching
            [ "$THERMAL_HOT" = "1" ] && _thermal_status=active
        fi
    else
        THERMAL_HOT=0
    fi
    if [ "$_old_hot" != "$THERMAL_HOT" ]; then
        log "温度策略：$_thermal_status mode=$THERMAL_MODE temp=${THERMAL_TEMP}mC threshold=${THERMAL_THRESHOLD}C"
    fi
}

