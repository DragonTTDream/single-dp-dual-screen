#!/usr/bin/env bash
# verify-status.sh —— 单线双屏补丁集 只读体检（无需 root）
# 检查项：内核 / 驱动 / 内核参数 / modeset / 连接器 / 核心①服务 / 核心④环境变量 / 症状计数 / vfio 残留（背景项）
# 只读 /sys 与 journal，不改任何东西。
set -u
PASS=0; FAIL=0; WARN=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN+1)); }
info() { echo "  [INFO] $*"; }

echo "===== 单线双屏补丁集 体检 $(date '+%F %T') ====="

echo "--- 1. 内核与驱动"
info "kernel: $(uname -r)"
if command -v nvidia-smi >/dev/null 2>&1; then
    info "nvidia: $(nvidia-smi --query-gpu=driver_version,name --format=csv,noheader 2>/dev/null || echo 'nvidia-smi 不可用')"
else
    info "nvidia-smi 不存在（纯 AMD 机器可忽略本项）"
fi

echo "--- 2. 核心②：NVIDIA 退出显示链"
if grep -q 'nvidia-drm.modeset=0' /proc/cmdline 2>/dev/null; then
    ok "cmdline 含 nvidia-drm.modeset=0"
elif grep -q 'nvidia-drm.modeset=1' /proc/cmdline 2>/dev/null; then
    bad "cmdline 仍是 nvidia-drm.modeset=1（NVIDIA 在显示链里，黑屏入口）"
else
    warn "cmdline 无 nvidia-drm.modeset 参数（驱动默认值决定行为，建议显式 =0）"
fi
if [ -e /sys/module/nvidia_drm/parameters/modeset ]; then
    m="$(cat /sys/module/nvidia_drm/parameters/modeset)"
    [ "$m" = "N" ] && ok "nvidia_drm.modeset = N" || bad "nvidia_drm.modeset = $m（期望 N）"
else
    info "nvidia_drm 模块未加载（无 NVIDIA 独显的机器正常）"
fi
if [ -f /etc/modprobe.d/00-nvidia-drm-modeset.conf ]; then
    ok "modprobe 落点在位: /etc/modprobe.d/00-nvidia-drm-modeset.conf"
else
    warn "缺 /etc/modprobe.d/00-nvidia-drm-modeset.conf（cmdline 之外的双保险落点）"
fi

echo "--- 3. 双屏连接器（MST）"
CONF=/etc/dp-mst-rescue.conf
if [ -r "$CONF" ]; then
    total=0; connected=0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"; line="$(echo "$line" | xargs 2>/dev/null || true)"
        [ -z "$line" ] && continue
        total=$((total+1))
        st="$(cat "/sys/class/drm/$line/status" 2>/dev/null || echo missing)"
        if [ "$st" = "connected" ]; then
            ok "$line: connected"; connected=$((connected+1))
        else
            bad "$line: $st（期望 connected）"
        fi
    done < "$CONF"
    info "期望 $total 块屏，在位 $connected 块"
else
    warn "$CONF 不可读——未配置期望连接器；当前 connected 的连接器："
    for s in /sys/class/drm/card*-*/status; do
        [ "$(cat "$s" 2>/dev/null)" = "connected" ] && info "  ${s%/status}"
    done
fi

echo "--- 4. 核心①：dp-mst-rescue 服务"
if command -v systemctl >/dev/null 2>&1; then
    en="$(systemctl is-enabled dp-mst-rescue.service 2>/dev/null)"
    case "$en" in
        enabled)  ok "dp-mst-rescue.service = enabled" ;;
        disabled) bad "dp-mst-rescue.service = disabled（未启用）" ;;
        *)        bad "dp-mst-rescue.service 未安装" ;;
    esac
    last="$(journalctl -u dp-mst-rescue -b -o cat --no-pager 2>/dev/null | grep -E 'OK:|SUCCESS:|WARNING:' | tail -1)"
    [ -n "$last" ] && info "本次开机: $last"
fi

echo "--- 5. 核心④：软件光标"
if [ -f "$HOME/.config/environment.d/50-kwin-sw-cursor.conf" ] || \
   grep -qs 'KWIN_FORCE_SW_CURSOR' "$HOME/.config/plasma-workspace/env/10-kwin-sw-cursor.sh" 2>/dev/null; then
    ok "KWIN_FORCE_SW_CURSOR 配置在位"
else
    warn "核心补丁④未安装（RA24 光标回归无防护）"
fi
if command -v pgrep >/dev/null 2>&1 && pgrep -x kwin_wayland >/dev/null 2>&1; then
    kw="$(pgrep -x kwin_wayland | head -1)"
    if [ -r "/proc/$kw/environ" ]; then
        if tr '\0' '\n' < "/proc/$kw/environ" 2>/dev/null | grep -q KWIN_FORCE_SW_CURSOR; then
            ok "运行中的 kwin (pid $kw) 已带上 KWIN_FORCE_SW_CURSOR"
        else
            warn "kwin (pid $kw) 环境里没有该变量（注销重登后生效）"
        fi
    else
        info "kwin pid $kw 属主非当前用户（如 greeter），environ 不可读，跳过"
    fi
fi

echo "--- 6. 症状计数（本次开机，都应接近 0）"
ra24="$(journalctl -b -k -o cat --no-pager 2>/dev/null | grep -c 'Unsupported screen format RA24')"
atomic="$(journalctl -b -o cat _COMM=kwin_wayland --no-pager 2>/dev/null | grep -c 'Atomic modeset commit failed')"
lttp="$(journalctl -b -k -o cat --no-pager 2>/dev/null | grep -c 'LTTPR')"
[ "$ra24" -le 0 ] && ok "RA24 计数 = $ra24" || bad "RA24 计数 = $ra24（核心补丁④未生效？）"
[ "$atomic" -le 0 ] && ok "Atomic modeset 失败计数 = $atomic" || bad "Atomic modeset 失败计数 = $atomic"
info "LTTPR 计数 = $lttp（每次开机都有，良性，不具区分度）"

echo "--- 7. vfio 残留（背景项，与双屏无关）"
if lsmod 2>/dev/null | grep -q '^vfio'; then
    warn "vfio 模块仍在内存（本次开机由旧 initramfs 加载；确认配置已删后重启验证）"
else
    ok "lsmod 无 vfio（开机不再抢注显卡）"
fi

echo "===== 汇总: PASS=$PASS FAIL=$FAIL WARN=$WARN ====="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
