# ================================================================
# 可选组件停用（组 A~E）
# ----------------------------------------------------------------
# 做什么：
#   把「日常用不上、但后台常驻耗电」的系统组件整包停用（pm disable），
#   需要时再一键整包恢复（pm enable）。停用后该包不再被拉起、不再占内存、
#   不再周期性唤醒 CPU。
#
# 与锁核/限频的关系：
#   完全独立。锁核管 CPU 频点，限频管最大频率，本功能管「少起进程」。
#   三者叠加才是完整的省电链路，任一项关闭不影响其他项。
#
# 可逆性（最高原则，与模块设计哲学一致）：
#   - 停用记录写进 $FREEZE_STATE，卸载 / 服务退出 / 一键全恢复时逐条 enable
#   - 只碰 $FREEZE_TABLE 里白纸黑字列出的包，绝不按关键字批量匹配
#   - 表里任何一个包在本机不存在（pm list packages 查不到）就跳过，不报错
#   - 用户手动改回启用状态，下一轮会被「重新停用」——这是预期行为，
#     因为开关语义就是「这个组我要关掉」。要长期保留请直接关掉该组开关。
#   - 恢复用 pm enable 而非 pm install-existing：enable 对 SYSTEM 预装包
#     足够（本表全是 /system 或 /product 预装应用），不会触发重装流程
# ================================================================

FREEZE_STATE="$CONFIG_DIR/freeze.state"     # 已冻结包清单（包名<TAB>原始状态<TAB>冻结方式）
FREEZE_USER="${FREEZE_USER:-0}"             # 作用用户，0 = 机主

# ---- 分组表 ----------------------------------------------------
# 每行：组键|组显示名|包名（空格分隔）
# 选包原则：
#   1) 只选「后台耗电 / 常驻服务」类，不选任何会打断用户主动操作的组件
#   2) 不选任何影响通话、短信、基带、WiFi 连接、移动数据交换的包
#   3) 不选任何影响流量统计准确性的包
#   4) 不选桌面、输入法、相机、相册、时钟、通知、系统UI 等基础体验组件
# 注意：这里【不能用】行尾反斜杠续行！反斜杠会把换行一并吞掉，
# 导致五行合并成一整行，只有第一组被解析出来，其余四组静默失效。
# 正确写法是单引号多行字符串，每行自带真实换行。
#
# ================================================================
# ！！grp_self（作者自冻清单）高风险声明 —— 必读 ！！
# ================================================================
# 本组不是在「保守选包原则」下挑选的，而是作者本人在
#   ColorOS 16.0.1.306（一加 Ace 6T / PLJR110 / SM8650 平台）
# 上实测确认【能正常开机、日常功能可用】后冻结的 52 个包原样收录。
#
# 【其他系统版本不保证能正常进系统】
#   不同版本 / 不同机型里，同包名可能承担完全不同的职责，甚至被其它
#   系统组件硬依赖。例如：
#     com.coloros.securityguard      安全中心，可能参与系统完整性校验
#     com.coloros.securepay          支付保护框架，可能被支付链路强依赖
#     com.oplus.customize.coreapp    系统定制核心，可能参与开机配置stage
#     com.oplus.keyguard.*(6 个)     锁屏时钟/组件，全禁可能导致锁屏异常
#     com.heytap.colorfulengine      主题引擎，可能影响部分系统界面渲染
#     com.android.devicelockcontroller  设备锁控制器，可能参与开机校验
#     com.google.android.gms / gsf   停用后所有依赖 GMS 的应用会崩溃
#     com.google.android.marvin.talkback  无障碍服务，影响读屏用户
#   以上这些包被 pm disable 后【存在开不了机的真实风险】。
#
# 开启前请确保你已刷入救砖模块，并且能进入 Recovery 模式。
#
# 本组默认关闭（freeze_grp_self = false），不开启就完全不会动作。

FREEZE_TABLE='grp_log|运行日志收集|com.oplus.logkit com.oplus.onetrace com.android.traceur
grp_media|影音附加组件|com.coloros.karaoke com.oplus.audio.effectcenter com.oplus.mediaturbo com.oplus.smartmediacontroller
grp_cloud|云端备份同步|com.heytap.cloud com.android.sharedstoragebackup com.android.wallpaperbackup
grp_diag|系统行为诊断|com.oplus.appsense com.oplus.motionsense com.oplus.audiomonitor
grp_ad|广告推送聚合|com.heytap.mcs com.heytap.openid com.heytap.tas
grp_self|作者自冻清单（C16.0.1.306 实测）|com.heytap.colorfulengine com.heytap.openid com.heytap.pictorial com.heytap.speechassist com.heytap.tas com.microsoft.appmanager com.newcall com.oplus.acc.gac com.oplus.aicall com.oplus.aimemory com.oplus.aiwidgets com.oplus.aiwriter com.oplus.apprecover com.oplus.cardigitalkey com.oplus.cast com.oplus.cellularqoe com.oplus.customize.coreapp com.oplus.deepthinker com.oplus.encryption com.oplus.keyguard.clock.base com.oplus.keyguard.clock.gallery com.oplus.keyguard.clock.graffiti com.oplus.keyguard.clock.magazine com.oplus.keyguard.personality.clocks com.oplus.keyguard.style.widgets com.oplus.logkit com.oplus.matrix com.oplus.olc com.oplus.omoji com.oplus.onetrace com.oplus.owork com.oplus.remotecontrol com.oplus.travelengine com.coloros.karaoke com.coloros.ocrscanner com.coloros.remoteguardservice com.coloros.scenemode com.coloros.sceneservice com.coloros.securepay com.coloros.securityguard com.coloros.sharescreen com.coloros.systemclone com.coloros.translate.engine com.coloros.video com.fido.fido2client com.google.android.gms com.google.android.gsf com.google.android.marvin.talkback com.google.android.projection.gearhead com.android.devicelockcontroller com.coloros.codebook com.coloros.colordirectservice
grp_ai|AI 附加功能|com.oplus.aimemory com.oplus.aiunit com.oplus.aiwidgets com.oplus.aiwriter com.oplus.metis com.oplus.obrain
grp_voice|语音助手|com.oplus.ovoicemanager com.oplus.ovoicemanager.wakeup com.heytap.speechassist
grp_games|游戏空间|com.oplus.games com.oplus.cosa
grp_themes|主题与杂志|com.oplus.themestore com.heytap.themestore com.heytap.pictorial
grp_search|桌面搜索与负一屏|com.heytap.quicksearchbox com.coloros.assistantscreen com.coloros.ocs.opencapabilityservice'

# 取某个组的包名列表（组键不存在则输出空）
freeze_group_pkgs() {
    # 注意：本机 BusyBox ash 下 ${var%%|*} / ${var#*|} 处理 "|" 分隔符会失效
    #      （| 被当成特殊字符，展开结果为空或原串），必须改用 cut 切分。
    echo "$FREEZE_TABLE" | while IFS= read -r _line; do
        [ -z "$_line" ] && continue
        _k=$(echo "$_line" | cut -d"|" -f1)
        [ "$_k" = "$1" ] || continue
        echo "$_line" | cut -d"|" -f3-
    done
}

# 组开关读取：config.json 里 freeze_grp_log = true / false
freeze_group_on() {
    [ "$(cfg_bool "freeze_$1" false)" = "true" ]
}

# Adapted from starlifezzz/Logd_Disabler_ColorOS16 service.sh.
# Upstream: https://github.com/starlifezzz/Logd_Disabler_ColorOS16
# Reuse authorized by the upstream author, as reported by the CoreGate maintainer.
# CoreGate adaptations: lazy su probe, validated arguments, checked exit status,
# exact package queries and existing restore journal; no legacy suspend migration,
# upstream package stop and two-pass pkill cleanup retained.
PMX_INITIALIZED=0
PMX_USE_SU=0
pmx_init() {
    [ "$PMX_INITIALIZED" = 1 ] && return 0
    PMX_INITIALIZED=1
    if command -v su >/dev/null 2>&1 &&
       su -c id 2>/dev/null | grep -q 'uid=0'; then
        PMX_USE_SU=1
    fi
}
pmx() {
    local OLDIFS=$IFS rc
    pmx_init
    IFS=$(printf ' \t\n')
    if [ "$PMX_USE_SU" = "1" ]; then
        su -c "$*" 2>/dev/null
    else
        "$@" 2>/dev/null
    fi
    rc=$?
    IFS=$OLDIFS
    return "$rc"
}

pmx_verbose() {
    local OLDIFS=$IFS rc
    pmx_init
    IFS=$(printf ' \t\n')
    if [ "$PMX_USE_SU" = "1" ]; then
        su -c "$*" 2>&1
    else
        "$@" 2>&1
    fi
    rc=$?
    IFS=$OLDIFS
    return "$rc"
}

freeze_pms_ready() {
    pmx_init
    pmx pm list packages --user "$FREEZE_USER" | grep -q '^package:'
}
freeze_wait_pms() {
    local attempt=0
    while [ "$attempt" -lt 120 ]; do
        freeze_pms_ready && return 0
        attempt=$((attempt + 1))
        sleep 1
    done
    log "冻结：PackageManager 在 120 秒内未就绪，保留策略等待重试"
    return 1
}

# 包是否真实存在于本机（避免对不存在的包反复 pm disable 刷日志）
pkg_exists() {
    pmx pm list packages --user "$FREEZE_USER" 2>/dev/null | grep -qxF "package:$1"
}

# 包当前是否已被停用（不管是本模块停的还是用户自己停的）
pkg_is_disabled() {
    pmx pm list packages -d --user "$FREEZE_USER" 2>/dev/null | grep -qxF "package:$1"
}

# ---------------- 停用记录 ----------------
# 格式：每行「包名<TAB>原始状态」，原始状态 ∈ {enabled, disabled}
# 为什么要记原始状态：
#   用户可能在自己动手停用过某个组件（本机实测就有 5 个候选包处于手动停用态）。
#   如果我们只记「本模块停过它」，那恢复时一律 pm enable，就会把用户【原本
#   主动停用】的组件强行打开 —— 这是对用户设置的破坏。
#   记下原始状态后，恢复时严格按原样还原：
#     原始 enabled  → pm enable   （回到用户原本的启用态）
#     原始 disabled → 保持停用     （原本就不该开，别多管闲事）
freeze_is_recorded() {
    [ -f "$FREEZE_STATE" ] && awk -F'\t' -v p="$1" '$1==p{found=1}END{exit !found}' "$FREEZE_STATE" 2>/dev/null
}
# 取某包被记录时的原始状态
freeze_orig_state() {
    [ -f "$FREEZE_STATE" ] || return 1
    awk -F'\t' -v p="$1" '$1==p{print $2; exit}' "$FREEZE_STATE" 2>/dev/null
}
freeze_record_add() {  # $1=pkg $2=原始状态
    freeze_is_recorded "$1" && return 0
    printf '%s\t%s\n' "$1" "$2" >> "$FREEZE_STATE" 2>/dev/null
}
freeze_record_del() {
    [ -f "$FREEZE_STATE" ] || return 0
    awk -F'\t' -v p="$1" '$1!=p' "$FREEZE_STATE" > "$FREEZE_STATE.tmp" 2>/dev/null
    mv "$FREEZE_STATE.tmp" "$FREEZE_STATE" 2>/dev/null
}

# 记录/更新某包使用的冻结方式（第 3 列统一写 disable）。
# 新版使用停用/启用，不执行旧挂起状态迁移。
freeze_record_set_mode() {  # $1=pkg $2=mode
    [ -f "$FREEZE_STATE" ] || return 0
    awk -F'\t' -v p="$1" -v m="$2" 'BEGIN{OFS="\t"}
        $1==p { print $1, $2, m; done=1; next }
        { print }
        END { if (!done) print p, "enabled", m }
    ' "$FREEZE_STATE" > "$FREEZE_STATE.tmp" 2>/dev/null && mv "$FREEZE_STATE.tmp" "$FREEZE_STATE" 2>/dev/null
}

# 按包名停止进程（参考实现的 CoreGate 适配，避免命令行子串误杀）
#
# 【为什么不换 pgrep -U】
#   参考模块 v2.3.1 的回滚注释记录得很清楚：pgrep -U 在 Android 上不安全，
#   某些实现会返回全部 PID，配合 kill -9 会误杀 system_server 导致黑屏。
#   所以这里只对明确包名执行 am force-stop。
kill_pkg_procs() {
    local pkg="$1"
    local i
    # 【v2.0.3】先 am force-stop（对 persistent 进程有效，会连同其所有服务/广播一起终止）
    am force-stop "$pkg" 2>/dev/null
    for i in 1 2; do
        if pkill -f "$pkg" 2>/dev/null; then
            log "  🔪 已终止残留进程: $pkg (第${i}次)"
            sleep 2
        else
            [ "$i" = "1" ] && log "  📭 无残留进程: $pkg"
            return 0
        fi
    done
    log "  ⚠️ $pkg 持续存活（persistent），已尝试多轮强杀"
}

# 挂起状态须针对当前用户核实，不能把停用等同于冻结。



# Upstream disable_pkg / enable_pkg with CoreGate state verification adapters.
# Upstream ownership helpers adapted to CoreGate's tab-delimited journal.
pkg_live_state() {
    freeze_pms_ready || { echo unavailable; return 1; }
    if ! pkg_exists "$1"; then echo missing
    elif pkg_is_disabled "$1"; then echo disabled
    else echo enabled; fi
}
record_orig() { freeze_record_add "$1" "$2"; }
get_keep() { :; } # Single-package overrides are resolved by freeze_sync_impl.
orig_state_of() {
    if [ "${FREEZE_EXPLICIT:-false}" = true ]; then echo enabled
    else
        local original
        original=$(freeze_orig_state "$1")
        echo "$original"
    fi
}

disable_pkg() {
    local pkg="$1"
    local keep_key="$2"
    # 【v2.3.19-fix】归属判定：首次触碰先登记基线（模块安装前的真实状态）。
    # 基线非 enabled（用户自己已禁用 / 已卸载 / 本机无此包）→ 本模块不接管，
    # 既不 disable 也不在将来"恢复"它 —— 用户既存状态必须原样保留。
    local _live _orig
    _live=$(pkg_live_state "$pkg")
    record_orig "$pkg" "$_live"
    _orig=$(orig_state_of "$pkg")
    if [ "$_orig" != "enabled" ]; then
        log "  ⏭️ 非本模块改动（基线=$_orig），跳过: $pkg"
        return 0
    fi
    # 【子包白名单】用户在 WebUI 单独启用（不禁用）的包
    if [ -n "$keep_key" ]; then
        local keep_val
        keep_val=$(get_keep "$keep_key")
        if [ -n "$keep_val" ]; then
            local k
            for k in $(echo "$keep_val" | tr ',' ' '); do
                if [ "$k" = "$pkg" ]; then
                    # 【修复】白名单包=用户在 WebUI 保留启用：
                    # 不仅“跳过禁用”，还必须确保其处于启用态——
                    # 若此前被 UI 总开关即时路径禁掉（pm disabled），
                    # 此处重新 pm enable 拉回，保证重启后与配置一一对应。
                    if pmx pm list packages -d --user 0 | grep -qF "package:$pkg"; then
                        log "  🔄 白名单包被禁用，恢复启用: $pkg"
                        result=$(pmx_verbose pm enable "$pkg")
                        log "  $result"
                    else
                        log "  ⏭️ 跳过（WebUI 白名单保留）: $pkg"
                    fi
                    return 0
                fi
            done
        fi
    fi
    # 检查包是否存在（对 user 0 可见；已禁用/卸载的也会被 pm list --user 0 过滤掉）
    if ! pmx pm list packages --user 0 | grep -qF "$pkg"; then
        log "  ⏭️ 跳过（不存在或已禁用/卸载）: $pkg"
        return 0
    fi
    # 方法1：pm disable-user --user 0
    result=$(pmx_verbose pm disable-user --user 0 "$pkg")
    if echo "$result" | grep -qiE "new state: disabled|Success"; then
        log "  ✅ disable-user 成功: $pkg"
        kill_pkg_procs "$pkg"
        return 0
    fi
    log "  ⚠️ disable-user 失败: $pkg ($result)"
    # 【2026-10-02 事故】此处曾有"方法2：pm uninstall -k --user 0"fallback，
    # 与手动卸载 thirdkit 致不开机的命令同族（见 coloros.md P0），已移除。
    # 永不卸载：失败只允许继续"停用"，绝不做减法。
    # 方法2：pm disable --user 0（全局禁用，persistent 应用专用兜底）
    # 【v2.0.3】com.coloros.lockassistant 等 persistent 应用无法被 disable-user
    # 禁用（系统立即重新拉起），改用全局 disable + 强杀进程组合。
    result2=$(pmx_verbose pm disable --user 0 "$pkg" 2>&1)
    if echo "$result2" | grep -qiE "new state: disabled|Success"; then
        log "  ✅ pm disable 成功（persistent 兜底）: $pkg"
        # persistent 应用禁用后系统会尝试重启，需多轮强杀
        kill_pkg_procs "$pkg"
        sleep 2
        kill_pkg_procs "$pkg"
        return 0
    fi
    log "  ❌ 两种方法均失败: $pkg ($result2)"
    return 1
}

enable_pkg() {
    local pkg="$1"
    local orig
    orig=$(orig_state_of "$pkg")
    if [ -z "$orig" ]; then
        # 无本模块改动记录（旧版升级且未走自举 / 从未触碰）→ 保持现状，不恢复
        log "  ⏭️ 无本模块改动记录，保持现状不恢复: $pkg"
        return 0
    fi
    if [ "$orig" != "enabled" ]; then
        log "  ⏭️ 基线为 $orig（用户既存/本机无此包），不恢复: $pkg"
        return 0
    fi
    local live
    live=$(pkg_live_state "$pkg")
    case "$live" in
        enabled)
            log "  ✅ 已启用（跳过）: $pkg"
            return 0 ;;
        missing)
            # 基线本是 enabled，现被用户卸载 → 尊重用户操作，不复活
            log "  ⏭️ 已被用户卸载，不复活: $pkg"
            return 0 ;;
    esac
    # live=disabled 且基线=enabled → 本模块禁的，还原
    local result
    result=$(pmx_verbose pm enable --user 0 "$pkg")
    if echo "$result" | grep -qiE "new state: enabled|Success"; then
        log "  ✅ enable 成功: $pkg"
        return 0
    fi
    log "  ⚠️ pm enable --user 0 失败: $pkg ($result)"
    # persistent 类包：全局 enable 兜底（对应 disable_pkg 的 pm disable 兜底）
    local result2
    result2=$(pmx_verbose pm enable "$pkg" 2>&1)
    if echo "$result2" | grep -qiE "new state: enabled|Success"; then
        log "  ✅ pm enable 成功（persistent 恢复）: $pkg"
        return 0
    fi
    log "  ❌ 两种恢复方法均失败: $pkg ($result2)"
    return 1
}

# CoreGate command adapters. No suspend/unsuspend migration.
freeze_off_pkg() {
    local _p="$1" FREEZE_EXPLICIT=false _rc
    freeze_pms_ready || return 1
    pkg_exists "$_p" || return 1
    record_orig "$_p" "$(pkg_live_state "$_p")" || return 1
    freeze_record_set_mode "$_p" disable || return 1
    disable_pkg "$_p"; _rc=$?
    [ "$_rc" = 0 ] && pkg_is_disabled "$_p"
}
freeze_on_pkg() {
    local _p="$1" FREEZE_EXPLICIT="${2:-false}"
    freeze_pms_ready || return 1
    if [ "$FREEZE_EXPLICIT" != true ]; then
        freeze_is_recorded "$_p" || return 0
        if [ "$(freeze_orig_state "$_p")" = disabled ]; then
            freeze_record_del "$_p"; return $?
        fi
    fi
    pkg_exists "$_p" || return 1
    enable_pkg "$_p" || return 1
    freeze_pms_ready && pkg_exists "$_p" || return 1
    pkg_is_disabled "$_p" && return 1
    freeze_record_del "$_p"
}

# 某个包是否还被【本组之外】的其它「已开启」组占用
# 为什么需要这个：grp_self（作者自冻 52 包）与原五组有 5 个重叠包
#   com.oplus.logkit / com.oplus.onetrace   → 也在 grp_log
#   com.coloros.karaoke                     → 也在 grp_media
#   com.heytap.openid / com.heytap.tas      → 也在 grp_ad
# 若不管重叠，关闭 grp_log 时会把仍被 grp_self 使用的 logkit 恢复启用，
# 于是「自冻组开着，包却被解冻了」——组开关语义被悄悄破坏。
# 处理原则：只要还有别的组是开着的、且包含该包，就不恢复它。
#   占用权归「开着的组」，只有所有包含它的组都关闭后才真正恢复。
freeze_pkg_used_by_other() {  # $1=pkg  $2=当前组键（跳过自身）
    _needle="$1"; _self_key="$2"
    echo "$FREEZE_TABLE" | while IFS= read -r _line; do
        [ -z "$_line" ] && continue
        _k=$(printf %s "$_line" | cut -d"|" -f1)
        [ "$_k" = "$_self_key" ] && continue
        _pkgs=$(printf %s "$_line" | cut -d"|" -f3-)
        :
        case " $_pkgs " in
            *" $_needle "*) freeze_group_on "$_k" && echo "$_k" ;;
        esac
    done
}

# 跨进程互斥；持有者退出后允许清理遗留锁。
freeze_lock() {
    _fl_wait=0
    while ! mkdir "$CONFIG_DIR/freeze.lock" 2>/dev/null; do
        _fl_owner=$(cat "$CONFIG_DIR/freeze.lock/pid" 2>/dev/null)
        case "$_fl_owner" in
            ''|*[!0-9]*) : ;;
            *) if ! kill -0 "$_fl_owner" 2>/dev/null; then
                   rm -f "$CONFIG_DIR/freeze.lock/pid"
                   rmdir "$CONFIG_DIR/freeze.lock" 2>/dev/null
                   continue
               fi ;;
        esac
        _fl_wait=$((_fl_wait + 1))
        [ "$_fl_wait" -ge 30 ] && return 1
        sleep 1
    done
    echo $$ > "$CONFIG_DIR/freeze.lock/pid"
}
freeze_unlock() {
    [ "$(cat "$CONFIG_DIR/freeze.lock/pid" 2>/dev/null)" = "$$" ] || return 0
    rm -f "$CONFIG_DIR/freeze.lock/pid"
    rmdir "$CONFIG_DIR/freeze.lock" 2>/dev/null
}

# 单包选择优先于分组；只保存用户明确操作过的包。
FREEZE_MANUAL="$CONFIG_DIR/freeze_manual"
freeze_manual_get() {
    [ -f "$FREEZE_MANUAL" ] || return 0
    awk -F '\t' -v p="$1" '$1==p {print $2; exit}' "$FREEZE_MANUAL"
}
freeze_manual_set() {
    _fm_pkg="$1"; _fm_value="$2"
    { [ ! -f "$FREEZE_MANUAL" ] || awk -F '\t' -v p="$_fm_pkg" '$1!=p' "$FREEZE_MANUAL";
      printf '%s\t%s\n' "$_fm_pkg" "$_fm_value";
    } > "$FREEZE_MANUAL.$$.tmp" && mv "$FREEZE_MANUAL.$$.tmp" "$FREEZE_MANUAL"
}
freeze_manual_del() {
    [ -f "$FREEZE_MANUAL" ] || return 0
    awk -F '\t' -v p="$1" '$1!=p' "$FREEZE_MANUAL" > "$FREEZE_MANUAL.$$.tmp" && mv "$FREEZE_MANUAL.$$.tmp" "$FREEZE_MANUAL"
}

# 主同步：把「已开启的组」确保停用、「已关闭的组」确保恢复
# 幂等，可以每轮循环调用，重复执行无副作用
#
# 【测试提示】用假 pm 做本地模拟时，务必让假函数的 list 分支正确识别 -d：
#   pm list packages -d  →  shift 后 $1 是 "packages"，"-d" 在 $2
# 若误把 $1 当成过滤条件，假 pm 会把【全部包】当成停用包返回，
# 于是 pkg_is_disabled 恒为真 → 引擎一次 pm 都不调用，只写记录，
# 测试却全绿 —— 这是最危险的一类虚假通过。改引擎或改测试后，
# 必须确认「开组后包状态真的变成 disabled」这条断言存在且为 PASS。
freeze_sync_impl() {
    # Do not silently succeed while PackageManager is unavailable at boot.
    freeze_pms_ready || return 1
    _fs_packages=$({ printf '%s\n' "$FREEZE_TABLE" | cut -d'|' -f3 | tr ' ' '\n';
        [ ! -f "$FREEZE_STATE" ] || cut -f1 "$FREEZE_STATE";
    } | sort -u)
    _fs_fail=0
    for _fs_pkg in $_fs_packages; do
        if ! pkg_exists "$_fs_pkg"; then
            # Retain owned records and surface incomplete recovery instead of false success.
            freeze_is_recorded "$_fs_pkg" && _fs_fail=1
            continue
        fi
        _fs_want=$(freeze_manual_get "$_fs_pkg")
        if [ -z "$_fs_want" ]; then
            _fs_want=false
            [ -n "$(freeze_pkg_used_by_other "$_fs_pkg" '')" ] && _fs_want=true
        fi
        if [ "$_fs_want" = true ]; then
            freeze_off_pkg "$_fs_pkg" || _fs_fail=1
        elif freeze_is_recorded "$_fs_pkg" || [ "$(freeze_manual_get "$_fs_pkg")" = false ]; then
            if [ "$(freeze_manual_get "$_fs_pkg")" = false ]; then
                freeze_on_pkg "$_fs_pkg" true || _fs_fail=1
            else
                freeze_on_pkg "$_fs_pkg" || _fs_fail=1
            fi
        fi
    done
    return "$_fs_fail"
}

freeze_sync() {
    freeze_lock || return 1
    freeze_sync_impl
    _fs_result=$?
    freeze_unlock
    return "$_fs_result"
}

# 全部恢复（服务退出 / 卸载 / 一键全恢复时调用）
# 严格按原始状态还原，原本 disabled 的保持 disabled
freeze_restore_all_impl() {
    local _restore_fail=0
    if [ -f "$FREEZE_STATE" ]; then
        _restore_pkgs=$(cut -f1 "$FREEZE_STATE")
        for _restore_pkg in $_restore_pkgs; do
            freeze_on_pkg "$_restore_pkg" || _restore_fail=1
        done
    fi
    return "$_restore_fail"
}
freeze_restore_all() {
    freeze_lock || return 1
    freeze_restore_all_impl
    local _restore_rc=$?
    freeze_unlock
    return "$_restore_rc"
}
freeze_clear_policy_and_restore() {
    freeze_lock || return 1
    local _clear_key _clear_rc=0
    for _clear_key in $(printf '%s\n' "$FREEZE_TABLE" | cut -d'|' -f1); do
        cfg_set_bool "freeze_$_clear_key" false || _clear_rc=1
    done
    if [ "$_clear_rc" = 0 ]; then
        rm -f "$FREEZE_MANUAL" || _clear_rc=1
    fi
    if [ "$_clear_rc" = 0 ]; then
        freeze_restore_all_impl || _clear_rc=1
    fi
    freeze_unlock
    return "$_clear_rc"
}

# 状态查询：输出当前实际被停用/挂起的包（不管是否本模块所为），供状态面板展示
# 每行格式：包名<TAB>方式（disabled / suspended）
#
# 【历史坑，务必别再踩】
#   旧实现尝试过三个命令取挂起列表：`pm suspend list packages`、
#   `pm get-suspended-packages`、`pm list packages -s`。
#   实测三者全都不能用：
#     · pm suspend list packages → IllegalArgumentException: Unknown target package: list
#     · pm get-suspended-packages → Unknown command
#     · pm list packages -s       → -s 的语义是「列出系统包(shared/system)」，
#                                   跟挂起毫无关系，却返回了一整屏系统包名，
#                                   旧代码把它当挂起列表输出，于是面板上
#                                   所有系统包都显示成「已挂起」——这就是误报的来源。
#   -s 这个错选最隐蔽：它退出码为 0、输出非空，看起来「成功」了。
#
# 【现行做法】挂起状态以 dumpsys 里每个包的 user 状态行为准，逐包解析：
#     User 0: ... suspended=true ...
#   dumpsys package 一次吐全部包，用 awk 在 awk 内维护「当前包名」上下文即可，
#   不需要为每个包单独跑一次 dumpsys（那要几百次进程启动，太慢）。
#   停用状态仍用 pm list packages -d（这个参数语义正确，实测可靠）。
freeze_status_report() {
    # 1) 停用列表：pm list packages -d 语义正确，直接采信
    pmx pm list packages -d --user "$FREEZE_USER" 2>/dev/null | sed 's/^package://' | sed 's/$/\tdisabled/'
    # 2) 挂起列表：从 dumpsys package 里按包名上下文找 suspended=true
    #    只认 user 0（FREEZE_USER 默认 0），与冻结时保持同一用户口径
    pmx dumpsys package --all-components packages 2>/dev/null | awk -v u="User $FREEZE_USER:" '
        /^[[:space:]]*Package \[/ {
            # 形如 "  Package [com.foo.bar] (abc123):"
            pkg = $0
            sub(/^[[:space:]]*Package \[/, "", pkg)
            sub(/\].*$/, "", pkg)
            next
        }
        {
            # 目标用户状态行形如：
            #     "    User 0: ceDataInode=... installed=true hidden=false suspended=false ..."
            # 前面有 4 个空格缩进，所以不能要求行首匹配，必须先剥掉前导空白。
            if (pkg != "" && index($0, "suspended=true") > 0) {
                line = $0
                sub(/^[[:space:]]+/, "", line)
                if (index(line, u) == 1) {
                    print pkg "\tsuspended"
                    pkg = ""
                }
            }
        }
    '
}


