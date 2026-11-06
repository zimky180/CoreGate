#!/system/bin/sh
# ================================================================
# CoreGate 核心门控 · service.sh
# ----------------------------------------------------------------
# 原理：
#   日常使用 -> 通过 /sys/devices/system/cpu/cpuN/online 封锁高频大核
#              （默认自动检测最高频簇，如骁龙 8 Gen 5 的 2 颗 3.8GHz 超大核）
#   打开游戏 -> 检测到前台包名命中「游戏列表」时，恢复全部核心
#   录屏/拍照 -> 检测到前台包名命中「录屏/相机清单」时，恢复全部核心
#   离开游戏/录屏/相机 -> 重新封锁
# ----------------------------------------------------------------
# 配置：/data/adb/CoreGate/config.json（由 App 写入，本脚本只读执行）
# 日志：/data/adb/modules/CoreGate/log/coregate.log（模块本体目录，卸载随模块一起清除）
# 状态：/data/adb/CoreGate/state（供 App 展示）
# ================================================================

MODDIR=${0%/*}
MODULE_ID=$(basename "$MODDIR")
CONFIG_DIR="/data/adb/CoreGate"
CONFIG_FILE="$CONFIG_DIR/config.json"
PACKAGES_FILE="$CONFIG_DIR/packages.txt"
CAPTURE_FILE="$CONFIG_DIR/capture.txt"
# 日志统一放模块本体目录下的 log 子目录；模块目录不可写时回退到配置目录
if [ -d "$MODDIR" ] && [ -w "$MODDIR" ]; then
    LOG_DIR="$MODDIR/log"
else
    LOG_DIR="$CONFIG_DIR/log"
fi
LOG_FILE="$LOG_DIR/coregate.log"
STATE_FILE="$CONFIG_DIR/state"
PID_FILE="$CONFIG_DIR/daemon.pid"
CORE_CTL_BACKUP="$CONFIG_DIR/corectl.state"
# 手动离线的核心清单（一行一个 cpu 编号）
# 为什么需要它：App 点击单个核心下线，如果只写 sysfs，
# 守护进程下一轮 do_lock / do_unlock 会按 LOCK_LIST 直接覆盖掉用户的操作。
# 所以必须把「用户手动关掉的核」持久化，让 do_lock 主动维持、do_unlock 临时恢复。
MANUAL_FILE="$CONFIG_DIR/manual_off"

# 录屏 / 相机内置默认包名（capture.txt 不存在或为空时兜底）
# 这类应用需要全部核心在线才能流畅编码（录屏）或成片（相机）
CAPTURE_DEFAULT="com.oplus.screenrecorder
com.coloros.screenrecorder
com.oneplus.screenrecord
com.android.systemui.screenrecord
com.oplus.camera
com.oneplus.camera
com.coloros.camera
com.android.camera"

mkdir -p "$LOG_DIR" 2>/dev/null

# ---------------- 日志（必须先于任何调用定义） ----------------
log() {
    echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null
    sz=$(wc -c < "$LOG_FILE" 2>/dev/null)
    if [ -n "$sz" ] && [ "$sz" -gt 262144 ]; then
        tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null
    fi
}
# 兼容旧版本：把散落在多处旧路径的历史日志并入新日志文件后清理
# 覆盖：/data/adb/CoreGate/coregate.log、模块根目录 coregate.log、模块根目录 log/（旧实现）、旧版其它命名
migrate_old_log() {
    for old_log in \
        "$CONFIG_DIR/coregate.log" \
        "$MODDIR/coregate.log" \
        "$CONFIG_DIR/service.log" \
        "$MODDIR/service.log"; do
        [ "$old_log" = "$LOG_FILE" ] && continue
        [ -f "$old_log" ] || continue
        {
            echo "[$(date '+%m-%d %H:%M:%S')] —— 以下为迁移前的历史日志（$old_log）——"
            cat "$old_log" 2>/dev/null
        } >> "$LOG_FILE" 2>/dev/null
        rm -f "$old_log" 2>/dev/null
    done
    # 清理模块根目录残留的旧 .tmp 截断临时文件
    rm -f "$MODDIR/coregate.log.tmp" "$CONFIG_DIR/coregate.log.tmp" 2>/dev/null
}

mkdir -p "$CONFIG_DIR"
migrate_old_log
# 配置缺失时用模块自带默认配置兜底（防止 App 清理后无游戏列表导致只锁不解）
if [ ! -f "$CONFIG_FILE" ] && [ -f "$MODDIR/config.example.json" ]; then
    cp -f "$MODDIR/config.example.json" "$CONFIG_FILE" 2>/dev/null
    chmod 0644 "$CONFIG_FILE" 2>/dev/null
fi
# 包名列表缺失时兜底：优先从旧 config.json 迁移，否则用模块自带默认列表
if [ ! -f "$PACKAGES_FILE" ]; then
    if [ -f "$CONFIG_FILE" ] && grep -q '"game_packages"' "$CONFIG_FILE" 2>/dev/null; then
        # 旧版迁移：从 config.json 的 game_packages 数组提取包名
        sed -n '/"game_packages"/,/]/p' "$CONFIG_FILE" 2>/dev/null \
            | grep -oE '"[^"]+"' | tr -d '"' | grep -v '^game_packages$' > "$PACKAGES_FILE"
    fi
    if [ ! -s "$PACKAGES_FILE" ] && [ -f "$MODDIR/packages.txt" ]; then
        cp -f "$MODDIR/packages.txt" "$PACKAGES_FILE" 2>/dev/null
    fi
    chmod 0644 "$PACKAGES_FILE" 2>/dev/null
fi
# 保留旧版 game_packages 字段：按行截断 JSON 会丢失后续设置或破坏单行配置。

# ---------------- 配置读取（config.json 每字段一行） ----------------
cfg_val() {  # 字符串
    k="$1"; d="$2"
    v=$(sed -n "s/.*\"$k\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$CONFIG_FILE" 2>/dev/null | head -1)
    [ -n "$v" ] && echo "$v" || echo "$d"
}
cfg_bool() {  # 布尔
    k="$1"; d="$2"
    # 注意：必须用扩展正则(-E)，BusyBox 的 BRE 模式不支持 \(a\|b\) 交替语法，
    # 用 BRE 会解析为空导致所有布尔项回退默认值（真机 v1.36.1 实测确认）。
    v=$(sed -nE "s/.*\"$k\"[[:space:]]*:[[:space:]]*(true|false).*/\1/p" "$CONFIG_FILE" 2>/dev/null | head -1)
    [ -n "$v" ] && echo "$v" || echo "$d"
}
cfg_int() {  # 数字
    k="$1"; d="$2"
    v=$(sed -nE "s/.*\"$k\"[[:space:]]*:[[:space:]]*(-?[0-9]+)[[:space:]]*([,}].*)?$/\1/p" "$CONFIG_FILE" 2>/dev/null | head -1)
    [ -n "$v" ] && echo "$v" || echo "$d"
}

# 写入单个布尔字段。不存在则追加，存在则原地替换该行。
# 为什么需要它：APK 切开关不能整文件重写 —— APK 只认识自己那几个键，
# 重写会把 auto_lock_count 这类它不管的字段抹掉；而 shell 整文件重写
# 又有写一半掉电的风险。这里只改目标那一行，再原子替换整个文件。
# 用 awk 而不是 sed：sed 的替换串要写反斜杠和换行，经多层传参极容易
# 被吞掉（实测踩过：\1 变成控制字符、\n 变成真换行）。awk 用 -v 传值，
# 字符串里一个反斜杠都不用写，没有转义地狱。
cfg_set_bool() {  # $1=键 $2=true|false
    _k="$1"; _v="$2"
    [ -f "$CONFIG_FILE" ] || return 1

    # 第一步：逐行扫描，命中就改值；全程没命中则 exit 7 表示需要追加
    awk -v k="$_k" -v v="$_v" '
        function q(str) { return "\"" str "\"" }
        {
            if (!done && index($0, q(k)) > 0) {
                pat = q(k) "[ \t]*:[ \t]*"
                if (match($0, pat)) {
                    pre = substr($0, 1, RSTART + RLENGTH - 1)
                    tail = substr($0, RSTART + RLENGTH)
                    sub(/^(true|false)/, "", tail)
                    print pre v tail
                    done = 1
                    next
                }
            }
            print
        }
        END { if (!done) exit 7 }
    ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" 2>/dev/null
    _rc=$?

    if [ "$_rc" = "0" ]; then
        if [ -s "$CONFIG_FILE.tmp" ]; then
            mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
            chmod 0644 "$CONFIG_FILE" 2>/dev/null
            return 0
        fi
        rm -f "$CONFIG_FILE.tmp"
        return 1
    elif [ "$_rc" != "7" ]; then
        rm -f "$CONFIG_FILE.tmp"
        return 1
    fi

    # 插入根对象最后的闭合括号，兼容单行、空对象和末尾空行。
    rm -f "$CONFIG_FILE.tmp"
    awk -v k="$_k" -v v="$_v" '
        { text = text $0 "\n" }
        END {
            sub(/[ \t\r\n]+$/, "", text)
            if (text !~ /^ *\{/ || text !~ /} *$/) exit 1
            sub(/} *$/, "", text)
            sub(/[ \t\r\n]+$/, "", text)
            if (text !~ /\{$/) text = text ","
            printf "%s\n  \"%s\": %s\n}\n", text, k, v
        }
    ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" 2>/dev/null || {
        rm -f "$CONFIG_FILE.tmp"; return 1;
    }
    [ -s "$CONFIG_FILE.tmp" ] || return 1
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE" || return 1
    chmod 0644 "$CONFIG_FILE" 2>/dev/null

}

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

# 包是否真实存在于本机（避免对不存在的包反复 pm disable 刷日志）
pkg_exists() {
    pm list packages --user "$FREEZE_USER" 2>/dev/null | grep -qxF "package:$1"
}

# 包当前是否已被停用（不管是本模块停的还是用户自己停的）
pkg_is_disabled() {
    pm list packages -d --user "$FREEZE_USER" 2>/dev/null | grep -qxF "package:$1"
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

# 记录/更新某包使用的冻结方式（第 3 列：suspend / disable）
# 为什么单独一列：恢复时要知道该走 pm unsuspend 还是 pm enable，
# 走错了会留下「包还挂起但记录已删」的孤儿状态。
freeze_record_set_mode() {  # $1=pkg $2=mode
    [ -f "$FREEZE_STATE" ] || return 0
    awk -F'\t' -v p="$1" -v m="$2" 'BEGIN{OFS="\t"}
        $1==p { print $1, $2, m; done=1; next }
        { print }
        END { if (!done) print p, "enabled", m }
    ' "$FREEZE_STATE" > "$FREEZE_STATE.tmp" 2>/dev/null && mv "$FREEZE_STATE.tmp" "$FREEZE_STATE" 2>/dev/null
}

# 强杀某包的进程（对齐 Logd_Disabler_ColorOS16 的 kill_pkg_procs）
#
# 【为什么不换 pgrep -U】
#   参考模块 v2.3.1 的回滚注释记录得很清楚：pgrep -U 在 Android 上不安全，
#   某些实现会返回全部 PID，配合 kill -9 会误杀 system_server 导致黑屏。
#   所以这里只对明确包名执行 am force-stop。
kill_pkg_procs() {
    am force-stop --user "$FREEZE_USER" "$1" >/dev/null 2>&1
    return 0
}

# 挂起状态须针对当前用户核实，不能把停用等同于冻结。
pkg_is_suspended() {
    local _suspend_dump
    _suspend_dump=$(dumpsys package "$1" 2>/dev/null) || return 2
    printf '%s
' "$_suspend_dump" | awk -v u="User $FREEZE_USER:" '
        index($0, u) { found=1; if ($0 ~ /suspended=true/) yes=1; exit }
        END { if (!found) exit 2; exit !yes }'
}
freeze_record_mode() {
    [ -f "$FREEZE_STATE" ] || return 0
    awk -F'	' -v p="$1" '$1==p {print $3; exit}' "$FREEZE_STATE"
}

# 只挂起；设备拒绝挂起时明确报错，不改为停用应用。
freeze_off_pkg() {
    local _p="$1" _mode _susp_rc
    pkg_exists "$_p" || return 1
    if freeze_is_recorded "$_p"; then
        case "$(freeze_orig_state "$_p")" in disabled|suspended) return 0;; esac
        _mode=$(freeze_record_mode "$_p")
        case "$_mode" in
            suspend) pkg_is_suspended "$_p" && return 0 ;;
            *)
                # 将旧版由本模块造成的停用恢复，再迁移到挂起。
                if pkg_is_disabled "$_p"; then
                    pm enable --user "$FREEZE_USER" "$_p" >/dev/null 2>&1
                    pkg_is_disabled "$_p" && return 1
                fi
                ;;
        esac
    else
        if pkg_is_disabled "$_p"; then
            freeze_record_add "$_p" disabled
            return $?
        fi
        pkg_is_suspended "$_p"; _susp_rc=$?
        if [ "$_susp_rc" = 0 ]; then
            freeze_record_add "$_p" suspended
            return $?
        fi
        [ "$_susp_rc" = 1 ] || return 1
        # 先记恢复信息，即使进程中断仍能解除本模块挂起。
        freeze_record_add "$_p" enabled || return 1
    fi
    freeze_record_set_mode "$_p" suspend || return 1
    pm suspend --user "$FREEZE_USER" "$_p" >/dev/null 2>&1
    pkg_is_suspended "$_p" || return 1
    kill_pkg_procs "$_p"
    log "组件挂起：$_p"
    return 0
}

# 根据记录恢复，失败时保留记录供重试。用户原有的停用/挂起保持原样。
freeze_on_pkg() {
    local _p="$1" _mode _orig _susp_rc
    freeze_is_recorded "$_p" || return 0
    _orig=$(freeze_orig_state "$_p")
    case "$_orig" in
        disabled|suspended) freeze_record_del "$_p"; return $? ;;
    esac
    if ! pkg_exists "$_p"; then freeze_record_del "$_p"; return $?; fi
    _mode=$(freeze_record_mode "$_p")
    case "$_mode" in
        suspend)
            pm unsuspend --user "$FREEZE_USER" "$_p" >/dev/null 2>&1 || return 1
            pkg_is_suspended "$_p"; _susp_rc=$?
            [ "$_susp_rc" = 1 ] || return 1
            ;;
        *)
            if pkg_is_disabled "$_p"; then
                pm enable --user "$FREEZE_USER" "$_p" >/dev/null 2>&1
                pkg_is_disabled "$_p" && return 1
            fi
            ;;
    esac
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
    _fs_packages=$(printf '%s\n' "$FREEZE_TABLE" | cut -d'|' -f3 | tr ' ' '\n' | sort -u)
    _fs_fail=0
    for _fs_pkg in $_fs_packages; do
        pkg_exists "$_fs_pkg" || continue
        _fs_want=$(freeze_manual_get "$_fs_pkg")
        if [ -z "$_fs_want" ]; then
            _fs_want=false
            [ -n "$(freeze_pkg_used_by_other "$_fs_pkg" '')" ] && _fs_want=true
        fi
        if [ "$_fs_want" = true ]; then
            freeze_off_pkg "$_fs_pkg" || _fs_fail=1
        elif freeze_is_recorded "$_fs_pkg"; then
            freeze_on_pkg "$_fs_pkg" || _fs_fail=1
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
freeze_restore_all() {
    freeze_lock || return 1
    local _restore_fail=0
    if [ -f "$FREEZE_STATE" ]; then
        _restore_pkgs=$(cut -f1 "$FREEZE_STATE")
        for _restore_pkg in $_restore_pkgs; do
            freeze_on_pkg "$_restore_pkg" || _restore_fail=1
        done
    fi
    freeze_unlock
    return "$_restore_fail"
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
    pm list packages -d --user "$FREEZE_USER" 2>/dev/null | sed 's/^package://' | sed 's/$/\tdisabled/'
    # 2) 挂起列表：从 dumpsys package 里按包名上下文找 suspended=true
    #    只认 user 0（FREEZE_USER 默认 0），与冻结时保持同一用户口径
    dumpsys package --all-components packages 2>/dev/null | awk -v u="User $FREEZE_USER:" '
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
do_lock() {
    local c _desired _manual _pass
    LOCK_STATE=""
    core_guard_enter || { log "核心控制繁忙，本轮跳过"; return 1; }
    if [ "$DISABLE_CC" = "true" ]; then disable_core_ctl; else restore_core_ctl; fi
    _manual=$(manual_list | xargs)
    # A manual choice replaces automatic suggestions, so selecting CPU5 does not add CPU7.
    if [ -n "$_manual" ] && [ "$(cfg_val lock_cores auto)" = auto ]; then
        _desired="$_manual"
    else
        _desired="$LOCK_LIST $_manual"
    fi
    # 温度额外名单在手动 / 自动日常名单确定后合并，避免被手动模式覆盖。
    _desired="$_desired $THERMAL_EXTRA_ACTIVE"
    for c in $_desired; do
        case "$c" in ''|0|*[!0-9]*) continue;; esac
        if cpu_online "$c"; then set_cpu "$c" 0 && sleep 1; fi
    done
    for _pass in 1 2 3; do core_restore_except "$_desired"; done
    for c in $_desired; do
        case "$c" in ''|0|*[!0-9]*) continue;; esac
        if cpu_online "$c"; then LOCK_STATE="${LOCK_STATE}${c}:fail "
        else LOCK_STATE="${LOCK_STATE}${c}:ok "; fi
    done
    core_guard_leave
}
do_unlock() {
    local c _pass _missing
    UNLOCK_FAILED=""
    core_guard_enter || { UNLOCK_FAILED="busy"; return 1; }
    # Keep core_ctl disabled while full-core performance is requested.
    # Its original values stay in the backup and are restored on exit/daily policy.
    disable_core_ctl
    for _pass in 1 2 3; do
        core_restore_except ""
        _missing=""
        for c in $(all_cpus); do
            [ "$c" = 0 ] && continue
            cpu_online "$c" || _missing="$_missing $c"
        done
        [ -z "$_missing" ] && break
        [ "$_pass" -lt 3 ] && sleep 1
    done
    UNLOCK_FAILED="$_missing"
    core_guard_leave
    if [ -n "$UNLOCK_FAILED" ]; then
        log "恢复未完成，仍离线:$UNLOCK_FAILED"
        return 1
    fi
    return 0
}
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

# ---------------- 前台应用检测（多路回退：覆盖 ColorOS 各类前台字段） ----------------
# 从一行文本中提取包名：优先取 "包名/Activity" 的包名，否则取首个形似包名的 token
_fg_extract() {
    sed -E 's/.*[ {]([a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+)\/[^ ]*.*/\1/' \
        | grep -oE '[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+' | head -1
}
fg_pkgs() {
    # 方式1：dumpsys window 多字段（全屏游戏/游戏空间/挂屏/焦点，取所有命中的包名）
    out=$(dumpsys window 2>/dev/null \
        | grep -E 'mCurrentFocus|mFocusedApp|mHoldScreenWindow|mTopFullscreenOpaque|mObscuringWindow|mLastFocusedWindow|mFocusedWindow' \
        | sed -E 's/.* ([a-zA-Z0-9.]+)\/.*/\1/' \
        | grep -E '^[a-zA-Z][a-zA-Z0-9_.]*$' | grep -v '^null$' | sort -u)
    if [ -n "$out" ]; then
        echo "$out"
        return
    fi
    # 方式2：activity 栈里的当前活跃 Activity（ColorOS 最可靠）
    out=$(dumpsys activity activities 2>/dev/null \
        | grep -m1 -E 'mResumedActivity|topResumedActivity|ResumedActivity' \
        | _fg_extract)
    [ -n "$out" ] && { echo "$out"; return; }
    # 方式3：dumpsys activity 的顶层信息（部分机型只有这里准）
    out=$(dumpsys activity 2>/dev/null \
        | grep -m1 -E 'mResumedActivity|topResumedActivity|ResumedActivity' \
        | _fg_extract)
    [ -n "$out" ] && { echo "$out"; return; }
    # 方式4：window 的焦点兜底
    out=$(dumpsys window 2>/dev/null \
        | grep -m1 -E 'mCurrentFocus|mFocusedApp' \
        | _fg_extract)
    echo "$out"
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

# ---------------- 屏幕 / 充电状态 ----------------
is_charging() {
    s=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
    if [ "$s" = "Charging" ] || [ "$s" = "Full" ]; then return 0; fi
    dumpsys battery 2>/dev/null | grep -qE 'AC powered: true|USB powered: true|Wireless powered: true'
}

# ---------------- 主循环 ----------------
LOCK_LIST=""
GAME_LIST=""
CAPTURE_LIST=""
LIMIT_FREQ="false"
AUTO_COUNT=1
DISABLE_CC="false"
SAFE_MODE=0
INTERVAL=10

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
    echo $$ > "$PID_FILE" 2>/dev/null
    rm -f "$CONFIG_DIR/high_cores"
    state=""; pkg=""; want_lock=""; last_pkg=""; lock_logged=0; ss=""; it2=0; last_ss=""
    prev_unlocked=0; oc_now=""

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
        do_unlock
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
        NO_CHARGE=$(cfg_bool no_lock_charging false)
        GAME_LIST=$(grep -v '^#' "$PACKAGES_FILE" 2>/dev/null | grep -v '^$')
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

        thermal_update

        # ---- 可选组件停用：必须放在主开关判断之前 ----
        # 原因：用户把模块主开关关掉、或进入安全模式时，下面会 continue 直接跳过本轮，
        # 而「组件停用」属于必须随主开关一起失效的功能，所以恢复动作要在这里先做。
        # 幂等：状态已同步时每轮只读文件、不真正调用 pm，开销可忽略。
        if [ "$ENABLED" != "true" ] || [ "$SAFE_MODE" = "1" ]; then
            thermal_publish
            freeze_restore_all
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

        # ---- 屏幕状态（sysfs 免费读取；无 backlight 的设备回退 dumpsys power，每 5 轮一次） ----
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
        # 游戏 或 录屏/相机：两者都需要全部核心在线，命中任一即不封锁
        GAME_ACTIVE=0
        if [ "$ss" != "OFF" ]; then
            if [ -n "$GAME_LIST" ] && is_game "$PKGS"; then GAME_ACTIVE=1; want_lock=no; fi
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
            if [ "$state" != "unlocked" ]; then
                log "切换为性能模式：恢复全部核心（前台: $pkg）"
            fi
            do_unlock
            remove_freq_cap
            if [ -z "$UNLOCK_FAILED" ]; then state="unlocked"; else state="unlock_partial"; fi
            if [ "$last_pkg" != "$pkg" ] || [ "$(cat "$STATE_FILE" 2>/dev/null)" != "$state|$pkg" ]; then
                last_pkg="$pkg"
                echo "$state|$pkg" > "$STATE_FILE"
            fi
        fi

        freeze_sync

        # ---- 间隔：完全由用户配置的 poll_interval 决定，不再有任何硬编码覆盖 ----
        # 只有"刚退出游戏 / 刚进入游戏"的过渡轮用 5 秒短间隔，让锁核状态尽快对齐；
        # 稳态（日常 / 息屏 / 持续游戏）一律按 INTERVAL 走，最大化省电。
        if [ "$state" != "locked" ]; then
            sleep "$INTERVAL"           # 游戏模式：按配置间隔
        elif [ "$prev_unlocked" = "1" ] || [ "$state_changed" = "1" ]; then
            sleep 5                     # 刚封锁完成的过渡轮：快速确认一次
        else
            sleep "$INTERVAL"           # 日常 / 息屏稳态：完整按用户配置间隔
        fi
    done
}

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
    if [ -n "$1" ]; then
        case "$1" in
            *[!0-9]*) : ;;
            *) AUTO_COUNT="$1"; [ "$AUTO_COUNT" -lt 1 ] && AUTO_COUNT=1;
               [ "$AUTO_COUNT" -gt 4 ] && AUTO_COUNT=4 ;;
        esac
    fi
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
                n="$1"
                [ "$n" -lt 1 ] && n=1
                [ "$n" -gt 4 ] && n=4
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
        # 日常模式维持手动清单；游戏 / 录屏 / 相机场景临时恢复全部核心。
        shift
        _c="$1"
        case "$_c" in ''|*[!0-9]*) echo "BADCPU"; exit 1;; esac
        if manual_add "$_c"; then
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
        freeze_sync_impl >/dev/null 2>&1
        _group_result=$?
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
            freeze_off_pkg "$_requested_pkg" && pkg_is_suspended "$_requested_pkg" &&
                freeze_manual_set "$_requested_pkg" true && _action_ok=0
            _action_mark=FREEZE_ADD
        else
            if freeze_on_pkg "$_requested_pkg"; then
                freeze_manual_set "$_requested_pkg" false && _action_ok=0
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
    --freeze-restore)
        # 一键全部恢复：把本模块停用过的组件全部启用
        rm -f "$FREEZE_MANUAL"
        freeze_restore_all || { echo "FREEZE_RESTORE_FAIL"; exit 1; }
        echo "FREEZE_RESTORE_DONE"
        exit 0
        ;;
    *)
        run
        ;;
esac