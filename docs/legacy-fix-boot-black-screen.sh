#!/usr/bin/env bash
# ============================================================================
# fix-boot-black-screen.sh
#
# 目标：消除「启动时黑屏、进不了桌面」的两个已定位主因
#
#   主因①  系统被切到 system-update.target（离线安装更新模式，按设计不启动桌面），
#          而 rhgb quiet + plymouth 在这套 MST 显示链路上渲染失败 → 全黑，看不到进度
#   主因②  KDE Discover 的 UseOfflineUpdates=true 会把更新暂存到下次启动执行
#
# 本脚本处理：移除 rhgb quiet / 关闭 Discover 离线更新 / 稳住 dnf-automatic
# 所有改动前先备份；可重复执行（幂等）。
#
# 用法：  sudo bash fix-boot-black-screen.sh
#         sudo bash fix-boot-black-screen.sh --with-iommu-cleanup   # 额外清掉无效的 amd_iommu=on
# ============================================================================
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "请用 sudo 运行：sudo bash $0" >&2
    exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
BK="/root/boot-black-screen-backup-$TS"
mkdir -p "$BK"

echo "==> 备份到 $BK"
cp -a /etc/default/grub        "$BK/grub.default"       2>/dev/null || true
cp -a /etc/xdg/discoverrc      "$BK/discoverrc.xdg"     2>/dev/null || true
cp -a /etc/dnf/automatic.conf  "$BK/automatic.conf"     2>/dev/null || true
grubby --info=ALL > "$BK/grubby-info.txt" 2>/dev/null || true
rpm -qa 'kernel*' | sort > "$BK/kernels.txt"
echo "    完成（要还原：把上面的文件拷回去，再跑 grub2-mkconfig）"

# ---------------------------------------------------------------------------
echo
echo "==> [1/3] 移除 rhgb quiet —— 以后能亲眼看到真实的启动/更新进度"
grubby --update-kernel=ALL --remove-args="rhgb,quiet"
echo "    当前内核参数："
grubby --info=DEFAULT 2>/dev/null | sed -n 's/^args="\(.*)"/      \1/p' || true

# ---------------------------------------------------------------------------
echo
echo "==> [2/3] 关闭 KDE Discover 的离线更新 —— 避免下次启动变成 system-update.target"
if [ -f /etc/xdg/discoverrc ]; then
    if grep -q '^UseOfflineUpdates=' /etc/xdg/discoverrc; then
        sed -i 's/^UseOfflineUpdates=.*/UseOfflineUpdates=false/' /etc/xdg/discoverrc
    else
        printf '[Software]\nUseOfflineUpdates=false\n' >> /etc/xdg/discoverrc
    fi
    echo "    /etc/xdg/discoverrc -> $(grep -m1 UseOfflineUpdates /etc/xdg/discoverrc)"
else
    printf '[Software]\nUseOfflineUpdates=false\n' > /etc/xdg/discoverrc
    echo "    已创建 /etc/xdg/discoverrc"
fi

# ---------------------------------------------------------------------------
echo
echo "==> [3/3] dnf-automatic 改为「只下载、不自动安装」"
if [ -f /etc/dnf/automatic.conf ]; then
    sed -i 's/^apply_updates *=.*/apply_updates = no/' /etc/dnf/automatic.conf
    echo "    现有设置：$(grep -E '^(upgrade_type|download_updates|apply_updates)' /etc/dnf/automatic.conf | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
echo
if [ "${1:-}" = "--with-iommu-cleanup" ]; then
    echo "==> [可选] 移除无效内核参数 amd_iommu=on（内核本来就会报 Unknown option 并忽略）"
    grubby --update-kernel=ALL --remove-args="amd_iommu=on"
    echo "    已移除，保留 iommu=pt"
else
    echo "==> [可选] 跳过 amd_iommu=on 清理（需要时加 --with-iommu-cleanup）"
fi

# ---------------------------------------------------------------------------
echo
echo "==> 检查是否还有待执行的离线更新"
if [ -e /system-update ]; then
    echo "    ⚠ /system-update 存在：仍有离线更新待执行，重启前请先让它跑完（别断电）"
    ls -l /system-update
else
    echo "    ✓ /system-update 不存在，当前没有待执行的离线更新"
fi

cat <<'TIP'

============================================================================
完成。接下来按顺序做：

A. 重新生成 GRUB 配置（BLS 模式下通常不必，但无害）
     sudo grub2-mkconfig -o /boot/grub2/grub.cfg

B. ★ 降低 MST 链路的带宽 —— 你的显示器没法换接法，这是最有效的软件手段
   现状：两台 2560x1440@180Hz，两路合计约 32.8 Gbps，
         而 DP1.4(HBR3 4lane) 有效载荷只有约 25.9 Gbps
         → 必须靠 DSC 硬压 → MST 时隙载荷分配失败 → 黑屏。
   实测日志已证实：MST_DSC + allocate_mst_payload WARNING + DM_MST 拓扑管理器反复重启。

   先降到 120Hz（约 21.9 Gbps，此时很可能连 DSC 都不需要了）：
     kscreen-doctor output.DP-5.mode.2560x1440@120 output.DP-11.mode.2560x1440@120

   观察一两天；若仍黑屏，再往下退：
     kscreen-doctor output.DP-5.mode.2560x1440@100 output.DP-11.mode.2560x1440@100
   也可以直接用「系统设置 → 显示与监视器」改，效果一样。
   （注：144Hz 约 26.7 Gbps，仍在 DP1.4 上限之上，所以还是要靠 DSC，意义不大。）

C. 显示器 OSD 设置（不用换线、不用换接法）
   - 把 DP 版本从「自动」改成固定 1.4
   - 试一次开/关 DSC（有些机器开 DSC 更稳，有些相反，各试一轮）
   - 关掉 FreeSync / Adaptive-Sync、关掉 HDR、色深固定 8bit
   - 确认走的是 MST，而不是显示器内部的 PBP 模式（PBP 通常更稳）

D. 刷主板 BIOS（AGESA）与显示器固件 —— MST / LTTPR 的修复大多在这两处

E. 验证（重启后执行，计数应显著降到 0 附近）
     journalctl -b -1 -k | grep -cE 'allocate_mst_payload|Unsupported screen format|LTTPR'
     journalctl -b -1 | grep -c 'Atomic modeset commit failed'
     # 默认目标必须回到 graphical.target，不应再出现 system-update.target：
     journalctl -b -1 | grep -oE 'default target [a-z.-]+' | sort -u

F. 万一以后又黑屏，先别急着重启（重启会打断离线更新）：
     - 按 Esc 看启动日志；按 Ctrl+Alt+F3 切到 TTY
     - 能进 TTY 就说明系统活着，多半是在装更新或显示配置没应用上
     - 检查： ls -l /system-update
============================================================================
TIP
