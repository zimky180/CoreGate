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
# 默认只锁 1 个（最稳，对应 Scene 实测可行的量），也可在 App 手动指定
detect_high() {
    _cap=${AUTO_COUNT:-1}
    case "$_cap" in ''|*[!0-9]*) _cap=1;; esac
    [ "$_cap" -lt 1 ] && _cap=1
    [ "$_cap" -gt 4 ] && _cap=4
    _maxf=0; _high=""
    for _policy in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$_policy" ] || continue
        _freq=$(cat "$_policy/cpuinfo_max_freq" 2>/dev/null)
        _members=$(cat "$_policy/related_cpus" 2>/dev/null)
        case "$_freq" in ''|*[!0-9]*) continue;; esac
        [ -n "$_members" ] || continue
        if [ "$_freq" -gt "$_maxf" ]; then
            _maxf=$_freq; _high="$_members"
        elif [ "$_freq" -eq "$_maxf" ]; then
            _high="$_high $_members"
        fi
    done
    # 无 policy 拓扑时只使用首次检测结果，避免离线后把次高频小核当成大核。
    if [ -z "$_high" ]; then
        if [ -s "$CONFIG_DIR/high_cores" ]; then
            _high=$(cat "$CONFIG_DIR/high_cores")
        else
            for _cpu in $(all_cpus); do
                _freq=$(cat "/sys/devices/system/cpu/cpu$_cpu/cpufreq/cpuinfo_max_freq" 2>/dev/null)
                case "$_freq" in ''|*[!0-9]*) continue;; esac
                if [ "$_freq" -gt "$_maxf" ]; then
                    _maxf=$_freq; _high="$_cpu"
                elif [ "$_freq" -eq "$_maxf" ]; then
                    _high="$_high $_cpu"
                fi
            done
            [ -n "$_high" ] && printf '%s\n' "$_high" > "$CONFIG_DIR/high_cores"
        fi
    fi
    [ -n "$_high" ] || _high=$(all_cpus | tail -n 1)
    printf '%s\n' $_high | grep -E '^[0-9]+$' | grep -v '^0$' | sort -nru | head -n "$_cap" | tr '\n' ' '
}
# ---------------- 手动离线核心（App 点击单核下线） ----------------
# 语义：manual_off 里记录的核，do_lock 会主动维持离线，do_unlock 在性能场景临时恢复。
# 只有用户再次点击该核（或「恢复全部核心」/ 卸载）才会从清单里移除。
manual_list() {
    [ -f "$MANUAL_FILE" ] || return 0
    while IFS= read -r _m; do
        _m=$(echo "$_m" | tr -d ' \r\t')
        case "$_m" in
            ''|*[!0-9]*) continue;;      # 非数字丢弃
            '0') continue;;              # cpu0 永不下线，即使被写进清单也忽略
        esac
        [ -d "/sys/devices/system/cpu/cpu$_m" ] || continue
        echo "$_m"
    done < "$MANUAL_FILE"
}
manual_has() {  # $1=cpu，在清单里返回0
    [ -f "$MANUAL_FILE" ] || return 1
    for _h in $(manual_list); do [ "$_h" = "$1" ] && return 0; done
    return 1
}
manual_add() {  # $1=cpu
    [ "$1" = "0" ] && return 1
    [ -d "/sys/devices/system/cpu/cpu$1" ] || return 1
    manual_has "$1" && return 0
    echo "$1" >> "$MANUAL_FILE" 2>/dev/null
    chmod 0644 "$MANUAL_FILE" 2>/dev/null
}
manual_del() {  # $1=cpu
    [ -f "$MANUAL_FILE" ] || return 0
    _tmp="$MANUAL_FILE.tmp"
    : > "$_tmp" 2>/dev/null
    for _k in $(manual_list); do
        [ "$_k" = "$1" ] && continue
        echo "$_k" >> "$_tmp" 2>/dev/null
    done
    if [ -s "$_tmp" ]; then
        mv -f "$_tmp" "$MANUAL_FILE" 2>/dev/null
    else
        rm -f "$_tmp" "$MANUAL_FILE" 2>/dev/null
    fi
    chmod 0644 "$MANUAL_FILE" 2>/dev/null
}
manual_clear() {
    rm -f "$MANUAL_FILE" "$MANUAL_FILE.tmp" 2>/dev/null
}

