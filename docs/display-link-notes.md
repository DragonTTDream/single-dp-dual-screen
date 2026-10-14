# 显示链路笔记（自 Deepseekword 并入 · 2026-09-29）

> **适配说明**：本文由原始机器档案并入本仓库（2026-10-14），内部链接已按仓库结构修正；机器专属路径以仓库内文件为准。

> **并入范围**：只有单线双屏的显示内容 —— 一条 DP 线经 MST 上两块屏（`card1-DP-4` 上 / `card1-DP-6` 下）。
> **来源**：源机器档案 `Deepseekword/fix-boot-black-screen.sh`，已于 2026-09-29 从该工作区删除；
> 原文**逐字存档**在本目录 [`legacy-fix-boot-black-screen.sh`](legacy-fix-boot-black-screen.sh)
> （6181 字节、127 行，与原文件字节数完全一致）。
> 来源中属于「无声意外重启」的内容一律不并入。
> **入口**：[`../README.md`](../README.md)——正式修复（P1/P2/P3）与第二道保险 `dp-mst-rescue/` 都在那里。
> 存档脚本**只留档、不要照跑**：它的根因判定与 `DP-5`/`DP-11` 连接器名已过时，见下面 §0。

## 0. 先说清楚：旧文件对黑屏的定性已被取代

旧文件把黑屏归因为两条：① 系统被切到 `system-update.target`（离线更新模式，按设计不启动桌面），
`rhgb quiet` + plymouth 在这条 MST 链路上渲染失败 → 全黑；② KDE Discover 的 `UseOfflineUpdates=true`
把更新暂存到下次启动执行。

**这两条都不是本机黑屏的主因。** 本机主因是 DP 链路训练不稳定：每次开机都报
`LTTPR count is nonzero but invalid lane count` + `lttpr_caps phy_repeater_cnt is 0x0, forcing it to 0x80`，
首次真实 modeset 时 amdgpu MST payload 分配竞态 → `Atomic modeset commit failed! 无效的参数`（EINVAL），
详见 [`../README.md`](../README.md) 的「背景」。

但旧文件的**链路侧**内容仍然有效 —— 尤其它解释了 P2 为什么要把 greeter 钉在 120Hz，故按主题并入下面各节。

## 1. 带宽账：为什么必须压到 120Hz

| 项 | 数值 |
| --- | --- |
| 单屏 2560x1440@180Hz | ≈ 16.4 Gbps |
| 双屏合计 @180Hz | ≈ **32.8 Gbps** |
| DP1.4（HBR3 4 lane）有效载荷 | ≈ **25.9 Gbps** |
| 双屏 @144Hz | ≈ 26.7 Gbps —— **仍在 DP1.4 上限之上**，还得靠 DSC，意义不大 |
| 双屏 @120Hz | ≈ **21.9 Gbps** —— 落回 DP1.4 之内，很可能连 DSC 都不需要 |

超限就必须靠 DSC 硬压，而 DSC 一上来，MST 时隙载荷分配就更容易失败（实测日志：`MST_DSC` +
`allocate_mst_payload` WARNING + `DM_MST` 拓扑管理器反复重启）→ 黑屏。
**这就是 P2 钉 120Hz 的原因，不是省电。**

运行时改刷新率（连接器名以当次开机的 `ls /sys/class/drm/card1-DP-*` 为准；本机现为 `card1-DP-4`/`card1-DP-6`，
旧文件里的 `DP-5`/`DP-11` 是更早一次开机的编号，已失效）：

```bash
kscreen-doctor output.DP-4.mode.2560x1440@120 output.DP-6.mode.2560x1440@120
# 观察一两天；仍黑屏再退一档：
kscreen-doctor output.DP-4.mode.2560x1440@100 output.DP-6.mode.2560x1440@100
```

（也可用「系统设置 → 显示与监视器」改，效果一样。）

## 2. 显示器 OSD 侧（不用换线、不用换接法）

- DP 版本：「自动」→ 固定 **1.4**
- DSC：**开 / 关各试一轮**（有些机器开 DSC 更稳，有些相反）
- 关掉 **FreeSync / Adaptive-Sync**、关掉 **HDR**、色深固定 **8bit**
- 确认走的是 **MST**，而不是显示器内部的 **PBP** 模式

## 3. 固件侧

刷**主板 BIOS（AGESA）**与**显示器固件** —— MST / LTTPR 的修复大多落在这两处。
（与现行排查呼应：本机每次开机都报 LTTPR 误读，这也是「换一根 DP 线验证」被列为候选手段的原因。）

## 4. 旧文件的系统侧动作 × 现状

| 旧文件动作 | 现在 |
| --- | --- |
| `grubby --update-kernel=ALL --remove-args="rhgb,quiet"` | P1 **已做过**；注意 **grubby 对 BLS 无效**，必须直接改 `/boot/loader/entries/*.conf` |
| `/etc/xdg/discoverrc` → `UseOfflineUpdates=false` | 与现行修复不冲突，可留 |
| `/etc/dnf/automatic.conf` → `apply_updates = no` | 与现行修复不冲突，可留 |
| `--with-iommu-cleanup`：`grubby --remove-args="amd_iommu=on"`（保留 `iommu=pt`） | P3 **已处理** |
| 备份到 `/root/boot-black-screen-backup-<时间戳>` | 现行备份在 `/root/boot-fix-backup-20260927-194851/` |
| （A 段）`grub2-mkconfig -o /boot/grub2/grub.cfg` | BLS 模式下通常不必，做了也无害 |

## 5. 验证（重启后跑，计数应降到 0 附近）

```bash
journalctl -b -1 -k | grep -cE 'allocate_mst_payload|Unsupported screen format|LTTPR'
journalctl -b -1 | grep -c 'Atomic modeset commit failed'
journalctl -b -1 | grep -oE 'default target [a-z.-]+' | sort -u   # 应回到 graphical.target
```

## 6. 再次黑屏时的自救

- 先别急着重启（重启会打断可能正在跑的离线更新）
- 按 `Esc` 看启动日志；按 `Ctrl+Alt+F3` 切到 TTY
- 能进 TTY 就说明系统活着，多半是在装更新或显示配置没应用上
- 检查：`ls -l /system-update`

## 7. 连接器名对照

- 旧文件写的 `DP-5` / `DP-11` → 已失效（那是更早一次开机的编号）
- 现行：`card1-DP-4`（上）/ `card1-DP-6`（下），见 [`../dp-mst-rescue/dp-mst-rescue.conf`](../dp-mst-rescue/dp-mst-rescue.conf)
