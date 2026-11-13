# One scalar snapshot per loop; never eval configuration as shell code.
_CG_CACHE_READY=0
_CG_CACHE_DIRTY=1
cfg_reload() {
    local _cg_new
    _cg_new=$(awk '
        {
            rest=$0
            while (match(rest, /"[A-Za-z_][A-Za-z0-9_]*"[[:space:]]*:/)) {
                key=substr(rest,RSTART,RLENGTH)
                sub(/^"/,"",key); sub(/"[[:space:]]*:$/,"",key)
                rest=substr(rest,RSTART+RLENGTH)
                sub(/^[[:space:]]*/,"",rest)
                if (match(rest, /^"([^"\\]|\\.)*"/)) {
                    value=substr(rest,2,RLENGTH-2); type="s"
                } else if (match(rest, /^(true|false)([[:space:],}]|$)/)) {
                    value=substr(rest,1,RLENGTH)
                    sub(/[[:space:],}].*/,"",value); type="b"
                } else if (match(rest, /^-?[0-9]+([[:space:],}]|$)/)) {
                    value=substr(rest,1,RLENGTH)
                    sub(/[[:space:],}].*/,"",value); type="i"
                } else continue
                rest=substr(rest,RLENGTH+1)
                id=type SUBSEP key
                if (!seen[id]++) print type "|" key "|" value
            }
        }
    ' "$CONFIG_FILE" 2>/dev/null) || { _CG_CACHE_READY=0; return 1; }
    _CG_SCALARS=$_cg_new
    _CG_CACHE_READY=1
    _CG_CACHE_DIRTY=0
}
cfg_cached() {
    local _cg_type _cg_key _cg_value
    while IFS='|' read -r _cg_type _cg_key _cg_value; do
        if [ "$_cg_type" = "$1" ] && [ "$_cg_key" = "$2" ]; then
            if [ -n "$_cg_value" ]; then printf '%s\n' "$_cg_value"
            else printf '%s\n' "$3"; fi
            return 0
        fi
    done <<EOF
$_CG_SCALARS
EOF
    printf '%s\n' "$3"
}
# ---------------- 配置读取（config.json 单行或多行） ----------------
cfg_val() {  # 字符串
    if [ "${_CG_CACHE_READY:-0}" = 1 ] && [ "${_CG_CACHE_DIRTY:-1}" = 0 ]; then
        cfg_cached s "$1" "$2"; return
    fi
    k="$1"; d="$2"
    v=$(sed -n "s/.*\"$k\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$CONFIG_FILE" 2>/dev/null | head -1)
    [ -n "$v" ] && echo "$v" || echo "$d"
}
cfg_bool() {  # 布尔
    if [ "${_CG_CACHE_READY:-0}" = 1 ] && [ "${_CG_CACHE_DIRTY:-1}" = 0 ]; then
        cfg_cached b "$1" "$2"; return
    fi
    k="$1"; d="$2"
    # 注意：必须用扩展正则(-E)，BusyBox 的 BRE 模式不支持 \(a\|b\) 交替语法，
    # 用 BRE 会解析为空导致所有布尔项回退默认值（真机 v1.36.1 实测确认）。
    v=$(sed -nE "s/.*\"$k\"[[:space:]]*:[[:space:]]*(true|false).*/\1/p" "$CONFIG_FILE" 2>/dev/null | head -1)
    [ -n "$v" ] && echo "$v" || echo "$d"
}
cfg_int() {  # 数字
    if [ "${_CG_CACHE_READY:-0}" = 1 ] && [ "${_CG_CACHE_DIRTY:-1}" = 0 ]; then
        cfg_cached i "$1" "$2"; return
    fi
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
    _CG_CACHE_DIRTY=1
    local _k="$1" _v="$2" _rc
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

