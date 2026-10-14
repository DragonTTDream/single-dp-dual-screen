#!/usr/bin/env bash
# ============================================================================
# apply-p4-sw-cursor.sh —— P4：强制 KWin 使用软件光标（修复「概率性进不去桌面」）
#
#   症状：greeter 正常、双屏都亮，但用户会话桌面随机起不来，只能重启。
#   根因：KWin 把光标平面按 RGBA8888(RA24) 交给 amdgpu，DC 拒绝该格式
#         （内核日志 `Unsupported screen format RA24 little-endian (0x34324152)`），
#         整个 atomic commit 返回 EINVAL → `Atomic modeset commit failed! 无效的参数`
#         → `Applying output configuration failed!` 每 ~6 秒重试、57 次后放弃 → 桌面起不来。
#         详见 docs/kwin-ra24-cursor-regression.md。
#
#   对策：KWIN_FORCE_SW_CURSOR=1（KWin 官方环境变量：直接用软件渲染光标，
#         不再去探测 DRM 光标平面）。写入两处，覆盖 KWin 的两种拉起路径：
#           ~/.config/environment.d/50-kwin-sw-cursor.conf        （systemd 用户管理器）
#           ~/.config/plasma-workspace/env/10-kwin-sw-cursor.sh   （startplasma-wayland 会话链）
#
#   无需 root（写的是当前用户的家目录）；注销重登即生效，不必重启。
#   用法：bash apply-p4-sw-cursor.sh [--status|--revert|--dry-run|-h]
# ============================================================================
set -euo pipefail

VAR_NAME="KWIN_FORCE_SW_CURSOR"
VAR_VALUE="1"

# ---- 目标用户 / 家目录（允许 sudo 运行但落到原用户） --------------------------
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
    TARGET_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
    TARGET_USER="$(id -un)"
    TARGET_HOME="$HOME"
fi
if [ "$(id -u)" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
    echo "请以桌面用户身份运行（不要直接 root）：bash $0" >&2
    exit 1
fi

CONF="$TARGET_HOME/.config/environment.d/50-kwin-sw-cursor.conf"
SH="$TARGET_HOME/.config/plasma-workspace/env/10-kwin-sw-cursor.sh"
CONF_BODY="$VAR_NAME=$VAR_VALUE"
SH_BODY="# KWin 软件光标 — 2026-09-29 P4：绕开 amdgpu 拒绝 RA24 光标平面导致的 atomic commit 失败
# 详见 docs/kwin-ra24-cursor-regression.md；回滚：apply-p4-sw-cursor.sh --revert
export $VAR_NAME=$VAR_VALUE"

MODE="install"
case "${1:-}" in
    --status)  MODE="status" ;;
    --revert)  MODE="revert" ;;
    --dry-run) MODE="dry-run" ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    "") : ;;
    *) echo "未知参数：$1（可用：--status / --revert / --dry-run / -h）" >&2; exit 2 ;;
esac

echo "==> 目标用户：$TARGET_USER（家目录 $TARGET_HOME），模式：$MODE"

show_status() {
    echo "--- 配置文件:"
    for f in "$CONF" "$SH"; do
        if [ -f "$f" ]; then
            echo "  [已装] $f"
            sed 's/^/         /' "$f"
        else
            echo "  [未装] $f"
        fi
    done
    echo "--- systemd 用户管理器环境:"
    if systemctl --user show-environment 2>/dev/null | grep -q "^$VAR_NAME="; then
        systemctl --user show-environment | grep "^$VAR_NAME=" | sed 's/^/  /'
    else
        echo "  未设置（或本 shell 连不上用户总线；已注销重登后应能看到）"
    fi
    echo "--- 正在跑的 KWin 进程环境:"
    local kwin_pid
    kwin_pid="$(pgrep -x kwin_wayland | head -1 || true)"
    if [ -n "$kwin_pid" ] && [ -r "/proc/$kwin_pid/environ" ]; then
        if tr '\0' '\n' < "/proc/$kwin_pid/environ" | grep -q "^$VAR_NAME="; then
            echo "  kwin_wayland (PID $kwin_pid) 已带 $VAR_NAME=$VAR_VALUE"
        else
            echo "  kwin_wayland (PID $kwin_pid) 尚未带该变量 —— 注销重登后生效"
        fi
    else
        echo "  （读不到 kwin_wayland 进程环境，跳过）"
    fi
}

case "$MODE" in
    status) show_status; exit 0 ;;
    dry-run)
        echo "--- 将写入:"
        echo "  $CONF:"; printf '%s\n' "$CONF_BODY" | sed 's/^/    /'
        echo "  $SH:";   printf '%s\n' "$SH_BODY"   | sed 's/^/    /'
        exit 0 ;;
    revert)
        for f in "$CONF" "$SH"; do
            if [ -f "$f" ]; then rm -f "$f"; echo "  已删除 $f"; else echo "  不存在，跳过 $f"; fi
        done
        echo ""
        echo "已回滚。注销重登（或重启）后 KWin 恢复探测硬件光标平面。"
        echo "注：若当时诊断的是 RA24 回归，回滚后概率性进不去桌面会重现。"
        exit 0 ;;
esac

# ---- 安装（幂等 + 备份） -----------------------------------------------------
TS="$(date +%Y%m%d-%H%M%S)"
BK="$TARGET_HOME/.config/boot-fix-backup-$TS"
BACKED_UP=0

put_file() { # $1=路径 $2=内容 $3=权限
    local path="$1" body="$2" mode="$3"
    if [ -f "$path" ] && [ "$(cat "$path")" = "$body" ]; then
        echo "  已是最新内容，跳过 $path"
        return 0
    fi
    if [ -f "$path" ]; then
        mkdir -p "$BK"; cp -a "$path" "$BK/$(basename "$path")"; BACKED_UP=1
        echo "  已备份原文件 → $BK/$(basename "$path")"
    fi
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$body" > "$path"
    chmod "$mode" "$path"
    echo "  已写入 $path（$mode）"
}

echo ""
echo "===== 写入环境变量 $VAR_NAME=$VAR_VALUE ====="
put_file "$CONF" "$CONF_BODY" 0644
put_file "$SH"   "$SH_BODY"   0755

if [ "$BACKED_UP" -eq 1 ]; then echo "备份目录：$BK"; fi

echo ""
echo "===== 安装后状态 ====="
show_status

cat <<'EOF'

===== 下一步 =====
1) 注销重登（或重启）—— environment.d 由 systemd 用户管理器在登录时读取，重登即可，不必重启。
2) 重登后确认变量已到 KWin：
     tr '\0' '\n' < /proc/$(pgrep -x kwin_wayland | head -1)/environ | grep KWIN_FORCE_SW_CURSOR
3) 确认症状消失（三条都应输出 0）：
     journalctl -b -k -o cat --no-pager | grep -c 'Unsupported screen format RA24'
     journalctl -b -o cat _COMM=kwin_wayland --no-pager | grep -c 'Atomic modeset commit failed'
     journalctl -b -o cat _COMM=kwin_wayland --no-pager | grep -c 'Applying output configuration failed'
4) 连续 3 次重启都能进桌面 → 判定修复；若仍失败，见 kwin-ra24-cursor-regression.md §8 备选。
EOF
