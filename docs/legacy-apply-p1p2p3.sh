#!/usr/bin/env bash
# ============================================================================
# apply-p1p2p3.sh —— 2026-09-27 一次性执行的开机修复合集（需 root）【存档】
# 与仓库核心主题的对应关系：
#   P1（rhgb quiet / Discover 离线更新 / dnf-automatic）= 背景修复，与单线双屏无直接关系
#   P2（sddm greeter 输出配置钉 120Hz）                 = 核心补丁③（单独安装见 README「安装」一节）
#   P3（vfio-pci 参数清理）                             = 背景修复，与单线双屏无关
# 仅作历史留档，勿当作双屏修复方案整跑。
#   P1: 移除 rhgb quiet（直接改 BLS 条目）/ 关 Discover 离线更新 / 稳 dnf-automatic
#   P2: 安装 sddm 用户的 kwinoutputconfig.json（greeter 钉 120Hz）
#   P3: 移除失效的 vfio-pci 直通参数（/etc/default/grub + BLS + classic grub.cfg）
# 所有改动先备份到 /root/boot-fix-backup-<时间戳>
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "请用 sudo 运行：sudo bash $0" >&2
    exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
BK="/root/boot-fix-backup-$TS"
mkdir -p "$BK"
echo "==> 备份目录：$BK"

# ============ P1 ============
echo ""
echo "===== P1: rhgb quiet / Discover 离线更新 / dnf-automatic ====="
# 前置版本 fix-boot-black-screen.sh 的逐字存档见本目录 legacy-fix-boot-black-screen.sh；
# 其仍有效的动作内联在这里（旧文件的定性见本目录 display-link-notes.md）：
# a) 移除 BLS 条目里的 rhgb quiet —— grubby 对 BLS 无效，必须直接改条目文件
#    （/etc/default/grub 里的 rhgb quiet 由下面 P3 的 sed 一起清掉）
for f in /boot/loader/entries/*.conf; do
    [ -e "$f" ] || continue
    if grep -qE ' rhgb| quiet' "$f"; then
        cp -a "$f" "$BK/$(basename "$f")"
        sed -i 's/ rhgb//g; s/ quiet//g' "$f"
        echo "  updated BLS: $f"
    fi
done

# b) 关闭 KDE Discover 的离线更新 —— 避免下次启动变成 system-update.target
if [ -f /etc/xdg/discoverrc ]; then
    cp -a /etc/xdg/discoverrc "$BK/discoverrc.xdg"
    if grep -q '^UseOfflineUpdates=' /etc/xdg/discoverrc; then
        sed -i 's/^UseOfflineUpdates=.*/UseOfflineUpdates=false/' /etc/xdg/discoverrc
    else
        printf '[Software]\nUseOfflineUpdates=false\n' >> /etc/xdg/discoverrc
    fi
    echo "  discoverrc -> $(grep -m1 UseOfflineUpdates /etc/xdg/discoverrc)"
else
    printf '[Software]\nUseOfflineUpdates=false\n' > /etc/xdg/discoverrc
    echo "  created /etc/xdg/discoverrc"
fi

# c) dnf-automatic 改成「只下载、不自动安装」
if [ -f /etc/dnf/automatic.conf ]; then
    cp -a /etc/dnf/automatic.conf "$BK/automatic.conf"
    sed -i 's/^apply_updates *=.*/apply_updates = no/' /etc/dnf/automatic.conf
    echo "  dnf-automatic -> $(grep -E '^apply_updates' /etc/dnf/automatic.conf)"
fi

# d) 检查是否还有待执行的离线更新（重启前别断电）
if [ -e /system-update ]; then
    echo "  ! /system-update 存在：仍有离线更新待执行"
    ls -l /system-update
fi

# ============ P2 ============
echo ""
echo "===== P2: sddm kwinoutputconfig.json ====="
STAGE="$HERE/../scripts/sddm-kwinoutputconfig.json"   # 脚本在 docs/，样本在 scripts/
install -d -m 0700 -o sddm -g sddm /var/lib/sddm/.config
if [ -f /var/lib/sddm/.config/kwinoutputconfig.json ]; then
    cp -a /var/lib/sddm/.config/kwinoutputconfig.json "$BK/sddm-kwinoutputconfig.json"
fi
install -m 0600 -o sddm -g sddm "$STAGE" /var/lib/sddm/.config/kwinoutputconfig.json
echo "P2 done: /var/lib/sddm/.config/kwinoutputconfig.json"

# ============ P3 ============
echo ""
echo "===== P3: 移除 vfio-pci 参数 ====="
cp -a /etc/default/grub "$BK/grub.default"
# 同步清掉 /etc/default/grub 里的 rhgb quiet（P1 的 grubby 只改 BLS 条目，
# 不清这里的话下次装新内核生成的 BLS 会重新带上）+ 失效的 vfio-pci 参数
sed -i 's/ rhgb//g; s/ quiet//g; s/ rd\.driver\.pre=vfio-pci//g; s/ vfio-pci\.ids=10de:2705,10de:22bb//g' /etc/default/grub

for f in /boot/loader/entries/*.conf; do
    [ -e "$f" ] || continue
    if grep -q 'vfio-pci' "$f"; then
        cp -a "$f" "$BK/$(basename "$f")"
        sed -i 's/ rd\.driver\.pre=vfio-pci//g; s/ vfio-pci\.ids=10de:2705,10de:22bb//g' "$f"
        echo "  updated BLS: $f"
    fi
done

if [ -f /boot/grub2/grub.cfg ] && grep -q 'vfio-pci' /boot/grub2/grub.cfg; then
    cp -a /boot/grub2/grub.cfg "$BK/grub.cfg"
    sed -i 's/ rd\.driver\.pre=vfio-pci//g; s/ vfio-pci\.ids=10de:2705,10de:22bb//g' /boot/grub2/grub.cfg
    echo "  updated classic: /boot/grub2/grub.cfg"
fi

# ============ 验证 ============
echo ""
echo "===== 验证 ====="
echo "--- /etc/default/grub:"
grep -E '^GRUB_CMDLINE_LINUX' /etc/default/grub
echo "--- BLS entries options:"
for f in /boot/loader/entries/*.conf; do
    [ -e "$f" ] || continue
    echo "  $f:"
    grep -E '^options' "$f" | sed 's/^/    /'
done
if [ -f /boot/grub2/grub.cfg ]; then
    echo "--- classic grub.cfg linux 行:"
    { grep -E '^[[:space:]]*linux' /boot/grub2/grub.cfg | sed 's/^/  /' || true; }
fi
echo "--- 残留 vfio（应为空）:"
{ grep -r 'vfio-pci' /etc/default/grub /boot/loader/entries/ /boot/grub2/grub.cfg 2>/dev/null || echo "  (none)"; }
echo ""
echo "全部完成。备份：$BK"
