#!/system/bin/sh
# ================================================================
# CoreGate 核心门控 · 动作按钮（KernelSU 管理器里的「执行」）
#
# v2.2.1 起配置入口全部收敛到原生 App，模块不再提供 WebUI。
# 但 KernelSU 的动作按钮完全由本文件是否存在决定：
#   - 没有 action.sh  → 管理器里连按钮都不出现
#   - 有 action.sh    → 出现按钮，点击执行本脚本
# 所以这个脚本的唯一职责：把用户直接送进 CoreGate App，
# 顺带在未安装 App / 未 Root 时给出人能看懂的提示。
#
# 设计约束（与模块哲学一致）：
#   - 只读不写：不改 config.json、不动 state、不触碰任何 sysfs
#   - 任何失败都只打印提示，绝不让管理器卡住
# ================================================================

MODDIR=${0%/*}

PKG_US="com.zimky.coregateUS"
PKG_OLD="com.zimky.coregate"
ACT="${PKG_US}/com.zimky.coregateUS.MainActivity"

# --- 找到一个已安装的 CoreGate ---
TARGET=""
if pm list packages 2>/dev/null | grep -qx "package:$PKG_US"; then
    TARGET="$PKG_US"
elif pm list packages 2>/dev/null | grep -qx "package:$PKG_OLD"; then
    TARGET="$PKG_OLD"
    ACT="${PKG_OLD}/com.zimky.coregate.MainActivity"
fi

if [ -z "$TARGET" ]; then
    echo "================================"
    echo " 没有找到 CoreGate App"
    echo "================================"
    echo ""
    echo "本模块的配置界面是独立的 App，需要单独安装。"
    echo "请到项目发布页下载 CoreGate-*.apk 安装后，再点一次「执行」。"
    echo ""
    echo "提示：不装 App 也能正常锁核，"
    echo "      模块会一直使用 /data/adb/CoreGate/config.json 里的配置运行。"
    echo ""
    echo "--- 当前模块运行状态（只读）---"
    if [ -f "/data/adb/CoreGate/daemon.pid" ]; then
        _p=$(cat "/data/adb/CoreGate/daemon.pid" 2>/dev/null)
        if [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null; then
            echo "守护进程：运行中 (PID $_p)"
        else
            echo "守护进程：未运行（PID 文件残留）"
        fi
    else
        echo "守护进程：未运行"
    fi
    if [ -f "/data/adb/CoreGate/state" ]; then
        echo "上次状态：$(cat /data/adb/CoreGate/state 2>/dev/null)"
    fi
    exit 0
fi

# --- 直接拉起 App ---
am start -n "$ACT" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    # 兜底：显式指定 action/category，兼容 Activity 名被改名的情况
    monkey -p "$TARGET" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
fi

echo "已打开 CoreGate App（$TARGET）"
echo ""
echo "App 内四页导航："
echo "  ① 锁核运行状态 / 核心状态 / 封锁核心"
echo "  ② 录屏·相机自动恢复 / 策略"
echo "  ③ 日常限频"
echo "  ④ 设置（含限频自定义、可选组件停用）"
exit 0
