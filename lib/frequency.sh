# ---------------- 日常限频（锁定安全频率上限，进一步省电） ----------------
# 设计取舍：
#   1) 用【绝对频率上限】而非百分比，避免不同核心硬件上限差异导致数学误差；
#   2) 写入值 = 目标MHz*1000 + 800，让内核向下对齐到最近的合法档次；
#   3) CPU 侧仅当【当前读数偏离目标】才写，避免无意义刷写带来的额外 CPU 唤醒与功耗；
#   4) CPU 的 scaling_max_freq 系统不会频繁回写，温和单写即可生效；
#      但 GPU 的 kgsl 节点（max_gpuclk / max_pwrlevel）会被系统周期性重设，
#      单写一次会被立刻改回，必须采用「chmod 644 解锁 → 连写 4 次 → chmod 444 锁定」
#      的强化写入方式，并在恢复时先 chmod 644 解锁再写回原值，保证完全可逆；
#   5) GPU 仅压 max_gpuclk / max_pwrlevel（省电天花板）与 devfreq，
#      写入频率需与 CPU 一样做 +800 对齐，否则精确值会被内核直接拒绝。
FREQ_CAPPED=0
# 锁定的安全上限（可在 App「限频目标档位」里自定义，存于 config.json）
# 优先级：config.json 的 cap_* 字段 > 这里的内置默认值。
# 之所以保留内置默认：老版本 config.json 没有这几个键，cfg_int 会回退到下面的兜底值，
# 保证「升级模块但没重新保存配置」时限频行为与旧版完全一致。
CAP_LITTLE_MHZ=2266      # policy0（小核簇）上限
CAP_BIG_MHZ=1651         # policy6（大核簇）上限
CAP_GPU_MHZ=500          # GPU 上限
CAP_GPU_PWRLEVEL=13      # GPU 最高功耗档位
# 从 config 读取自定义值；0 或非法值 = 未自定义，保留上面的默认
freq_cap_load_config() {
    CAP_LITTLE_MHZ=2266
    CAP_BIG_MHZ=1651
    CAP_GPU_MHZ=500
    CAP_GPU_PWRLEVEL=13
    _v=$(cfg_int cap_little_mhz 0)
    [ "$_v" -gt 0 ] 2>/dev/null && CAP_LITTLE_MHZ=$_v
    _v=$(cfg_int cap_big_mhz 0)
    [ "$_v" -gt 0 ] 2>/dev/null && CAP_BIG_MHZ=$_v
    _v=$(cfg_int cap_gpu_mhz 0)
    [ "$_v" -gt 0 ] 2>/dev/null && CAP_GPU_MHZ=$_v
    _v=$(cfg_int cap_gpu_pwrlevel -1)
    # pwrlevel 允许 0（0 就是最高性能档，是合法值），因此不能像上面三项那样用 >0 过滤。
    # App 用 -1 当「没设置过」的哨兵，这里只采纳 >=0 且 < num_pwrlevels 的值。
    if [ -n "$_v" ] && [ "$_v" -ge 0 ] 2>/dev/null; then
        _num=$(cat "$GPU_DIR/num_pwrlevels" 2>/dev/null)
        if [ -z "$_num" ] || [ "$_v" -lt "$_num" ] 2>/dev/null; then
            CAP_GPU_PWRLEVEL=$_v
        fi
    fi
}
GPU_RESTORE_MHZ=1225000000   # 恢复时 GPU 硬件上限
P0_DIR="/sys/devices/system/cpu/cpufreq/policy0"
P6_DIR="/sys/devices/system/cpu/cpufreq/policy6"
GPU_DIR="/sys/class/kgsl/kgsl-3d0"

# 仅当当前值偏离目标才写，减少无意义刷写
freq_write_if_needed() {
    _path="$1"; _target="$2"
    [ -e "$_path" ] || return 1
    _cur=$(cat "$_path" 2>/dev/null)
    [ "$_cur" = "$_target" ] && return 0
    echo "$_target" > "$_path" 2>/dev/null
}

# 对某个 cpu freq policy 目录设置 scaling_max_freq（+800 对齐）
cap_cluster() {
    _dir="$1"; _mhz="$2"
    [ -d "$_dir" ] || return 1
    _want=$(( _mhz * 1000 + 800 ))
    # 不超过该簇硬件上限
    _hw=$(cat "$_dir/cpuinfo_max_freq" 2>/dev/null)
    if [ -n "$_hw" ] && [ "$_want" -gt "$_hw" ]; then _want="$_hw"; fi
    freq_write_if_needed "$_dir/scaling_max_freq" "$_want"
}
# ---------------- 限频前状态快照（第2条需求：关闭限频必须还原到开启前的真实状态） ----------------
# 设计：首次开启限频时，把两簇当前的 scaling_max_freq 原值记录到
#   /data/adb/CoreGate/freq_snapshot（每簇一行：policy0=xxx、policy6=xxx）。
# 特点：
#   * 只在「快照文件不存在」时写入，之后绝不覆盖 —— 保证记录的是"用户真正开启前那一刻"的值；
#   * 存于 /data 用户数据区，重启不丢；
#   * 关闭限频时优先按快照还原，从而不需要重启、也不依赖内核虚标的 cpuinfo_max_freq。
FREQ_SNAP_FILE="$CONFIG_DIR/freq_snapshot"

# 读快照：传入簇目录，输出该目录的快照值（无则空）
freq_snapshot_get() {
    _d="$1"
    [ -f "$FREQ_SNAP_FILE" ] || return 0
    grep "^${_d}=" "$FREQ_SNAP_FILE" 2>/dev/null | tail -n 1 | sed 's/^[^=]*=//'
}
# 写快照：仅在文件不存在时创建，记录两簇当前 scaling_max_freq
freq_snapshot_save() {
    [ -f "$FREQ_SNAP_FILE" ] && return 0   # 已存在则绝不覆盖
    _p0=$(cat "$P0_DIR/scaling_max_freq" 2>/dev/null)
    _p6=$(cat "$P6_DIR/scaling_max_freq" 2>/dev/null)
    [ -z "$_p0" ] && [ -z "$_p6" ] && return 0
    {
        [ -n "$_p0" ] && echo "${P0_DIR}=${_p0}"
        [ -n "$_p6" ] && echo "${P6_DIR}=${_p6}"
    } > "$FREQ_SNAP_FILE" 2>/dev/null
}
# 清除快照（彻底恢复/清理残留时调用，让下次开启重新记录）
freq_snapshot_clear() {
    rm -f "$FREQ_SNAP_FILE" 2>/dev/null
}

# 真实最大合法档：优先取 scaling_available_frequencies 的最大值（内核真实认可的档位），
# 而不是 cpuinfo_max_freq —— 后者在部分机型是虚标/超频值，写进去会被内核拒绝或回弹，
# 导致「恢复」永远恢复不到真正满血。取不到时再回退 cpuinfo_max_freq。
real_max_freq() {
    _dir="$1"
    _max=""
    _r=$(cat "$_dir/scaling_available_frequencies" 2>/dev/null)
    if [ -n "$_r" ]; then
        for _f in $_r; do
            [ "$_f" -gt "${_max:-0}" ] 2>/dev/null && _max=$_f
        done
        if [ -n "$_max" ]; then echo "$_max"; return 0; fi
    fi
    cat "$_dir/cpuinfo_max_freq" 2>/dev/null
}
# 恢复某簇的 scaling_max_freq：
#   优先用「开启限频前的快照」还原到用户当时的真实状态（第2条需求）；
#   无快照时回退到该簇真实最大合法档（方案 A）。
restore_cluster() {
    _dir="$1"
    [ -d "$_dir" ] || return 1
    _snap=$(freq_snapshot_get "$_dir")
    if [ -n "$_snap" ]; then
        freq_write_if_needed "$_dir/scaling_max_freq" "$_snap"
        return 0
    fi
    _hw=$(real_max_freq "$_dir")
    [ -n "$_hw" ] && freq_write_if_needed "$_dir/scaling_max_freq" "$_hw"
}

# GPU(kgsl) 节点强化写入：系统会周期性重设 max_gpuclk / max_pwrlevel，
# 单写一次会被立刻改回，故需 chmod 644 解锁 → 连写 4 次 → sync → chmod 444 锁定。
# 恢复时由 gpu_restore_write 先 chmod 644 解锁再写回原值，保证可逆。
gpu_force_write() {
    _node="$1"; _val="$2"
    [ -e "$_node" ] || return 1
    i=0
    while [ "$i" -lt 4 ]; do
        chmod 644 "$_node" 2>/dev/null
        echo "$_val" > "$_node" 2>/dev/null
        i=$(( i + 1 ))
    done
    sync 2>/dev/null
    chmod 444 "$_node" 2>/dev/null
}
# 恢复专用：先 chmod 644 解开锁定，再写回原值（不重新锁定）
gpu_restore_write() {
    _node="$1"; _val="$2"
    [ -e "$_node" ] || return 1
    chmod 644 "$_node" 2>/dev/null
    _cur=$(cat "$_node" 2>/dev/null)
    [ "$_cur" = "$_val" ] && return 0
    echo "$_val" > "$_node" 2>/dev/null
}

apply_freq_cap() {
    [ "$LIMIT_FREQ" = "true" ] || return 0
    # 每轮循环都重新读一次阈值：App 里改完保存立即生效，无需重启模块。
    # 未配置（0 / 缺键）时该函数保持上面内置默认不变，行为与旧版一致。
    freq_cap_load_config
    # 首次开启限频：记录开启前的真实上限，供关闭时精确还原（第2条需求）
    freq_snapshot_save
    cap_cluster "$P0_DIR" "$CAP_LITTLE_MHZ"
    cap_cluster "$P6_DIR" "$CAP_BIG_MHZ"
    # GPU：功耗档位与频率上限（kgsl 节点需强化写入，频率需 +800000 对齐）
    gpu_clk=$(( CAP_GPU_MHZ * 1000000 + 800000 ))
    # 只压 max_pwrlevel（省电天花板），不动 min/default（地板与起跳点）：
    # 锁 max 即达成 500MHz 上限，压 min/default 不增加省电、反可能钳住降频下限，收益为零风险非零。
    gpu_force_write "$GPU_DIR/max_pwrlevel" "$CAP_GPU_PWRLEVEL"
    gpu_force_write "$GPU_DIR/max_gpuclk" "$gpu_clk"
    [ -e "$GPU_DIR/devfreq/max_freq" ] && gpu_force_write "$GPU_DIR/devfreq/max_freq" "$gpu_clk"
    [ "$FREQ_CAPPED" = "1" ] || log "已启用日常限频：小核≤${CAP_LITTLE_MHZ}MHz 大核≤${CAP_BIG_MHZ}MHz GPU≤${CAP_GPU_MHZ}MHz/档位${CAP_GPU_PWRLEVEL}"
    FREQ_CAPPED=1
}
remove_freq_cap() {
    # 不依赖内存变量 FREQ_CAPPED：服务重启/进程重入后该变量会归零，
    # 若此时内核里仍有残留锁定，旧写法会直接 return 0 导致"关不掉限制"。
    # 改为「先探内核实况，确有压制才恢复」，幂等且可重入。
    # 恢复基准：优先用开启限频前的快照，无快照则用真实最大合法档（方案 A），
    # 不再使用可能在部分机型虚标的 cpuinfo_max_freq。
    _restored=0
    if [ -d "$P0_DIR" ]; then
        _tgt0=$(freq_snapshot_get "$P0_DIR"); [ -z "$_tgt0" ] && _tgt0=$(real_max_freq "$P0_DIR")
        _cur0=$(cat "$P0_DIR/scaling_max_freq" 2>/dev/null)
        if [ -n "$_tgt0" ] && [ -n "$_cur0" ] && [ "$_cur0" != "$_tgt0" ]; then
            restore_cluster "$P0_DIR"; _restored=1
        fi
    fi
    if [ -d "$P6_DIR" ]; then
        _tgt6=$(freq_snapshot_get "$P6_DIR"); [ -z "$_tgt6" ] && _tgt6=$(real_max_freq "$P6_DIR")
        _cur6=$(cat "$P6_DIR/scaling_max_freq" 2>/dev/null)
        if [ -n "$_tgt6" ] && [ -n "$_cur6" ] && [ "$_cur6" != "$_tgt6" ]; then
            restore_cluster "$P6_DIR"; _restored=1
        fi
    fi
    if [ -d "$GPU_DIR" ]; then
        # 只在确实被压过时才恢复（幂等，避免无意义刷写）
        _gcur=$(cat "$GPU_DIR/max_gpuclk" 2>/dev/null)
        if [ -n "$_gcur" ] && [ "$_gcur" != "$GPU_RESTORE_MHZ" ]; then
            gpu_restore_write "$GPU_DIR/max_gpuclk" "$GPU_RESTORE_MHZ"
            _restored=1
        fi
        [ -e "$GPU_DIR/devfreq/max_freq" ] && gpu_restore_write "$GPU_DIR/devfreq/max_freq" "$GPU_RESTORE_MHZ"
        # 只恢复我们改过的 max_pwrlevel（解限 = 允许 GPU 跑最高性能档 0）；
        # min/default 本就没被 CoreGate 改过，绝不能动——
        # min_pwrlevel=0 会把 GPU 地板拉到最高频，反而更耗电。
        _gpwr=$(cat "$GPU_DIR/max_pwrlevel" 2>/dev/null)
        if [ -n "$_gpwr" ] && [ "$_gpwr" != "0" ]; then
            gpu_restore_write "$GPU_DIR/max_pwrlevel" "0"
            _restored=1
        fi
    fi
    FREQ_CAPPED=0
    if [ "$_restored" = "1" ]; then
        log "已取消日常限频，恢复硬件上限"
    fi
}

