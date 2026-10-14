# 单线双屏（DP 1.4 MST）开机修复补丁集

**简体中文** · [English](README.en.md)
希望能帮到有需要的朋友
> **一条 DP 线 → MST 菊花链 → 两块 2560×1440 屏**，挂在 AMD Raphael 核显上；NVIDIA 独显不接任何显示器、只做计算。
> 本仓库收录让这套拓扑**每次开机都稳定亮双屏、进桌面**的核心补丁与诊断记录。

[![Fedora](https://img.shields.io/badge/Fedora-44-blue)](https://fedoraproject.org/)
[![KDE Plasma](https://img.shields.io/badge/KDE_Plasma-Wayland-blueviolet)](https://kde.org/plasma-desktop/)
[![Kernel](https://img.shields.io/badge/kernel-7.2.10-informational)](https://kernel.org/)
[![nvidia](https://img.shields.io/badge/nvidia-615.78.08-76B900)](https://www.nvidia.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> 英文全文：[README.en.md](README.en.md)（逐节对应，非摘要）· 变更记录：[CHANGELOG.md](CHANGELOG.md) / [CHANGELOG.en.md](CHANGELOG.en.md)

## 目录

1. [问题是什么](#1-问题是什么)
2. [硬件与拓扑](#2-硬件与拓扑)
3. [核心补丁](#3-核心补丁)
4. [背景修复（非双屏本体）](#4-背景修复非双屏本体)
5. [本机实测状态（2026-10-14 核验）](#5-本机实测状态2026-10-14-核验)
6. [安装](#6-安装)
7. [验证](#7-验证)
8. [卸载 / 回滚](#8-卸载--回滚)
9. [带宽账：为什么必须钉 120Hz](#9-带宽账为什么必须钉-120hz)
10. [故障排查](#10-故障排查)
11. [引用的技术与仓库](#11-引用的技术与仓库)
12. [免责声明](#12-免责声明)

---

## 1. 问题是什么

| 症状 | 表现 |
| --- | --- |
| 开机黑屏 | 登录后概率性全黑，无 TTY，只能长按电源强关 |
| 开机只亮一屏 | MST 拓扑枚举不完整，两块屏只出来一块（曾 100% 复现于开机） |
| 桌面概率性进不去 | SDDM greeter 正常，进入 Plasma 会话后黑屏（约 2/3 失败率） |

根因分三层（逐层取证得出，证据链见 [docs/](docs/)）：

1. **DP 链路训练不稳定**：每次开机内核报 `LTTPR count is nonzero but invalid lane count` +
   `lttpr_caps phy_repeater_cnt is 0x0, forcing it to 0x80`；首次真实 modeset 时 amdgpu 的
   **MST payload 分配竞态** → KWin `Atomic modeset commit failed!（EINVAL）`。
2. **NVIDIA 驱动注册了它不使用的 KMS 设备**：`nvidia-drm.modeset=1` 时 NVIDIA 加入显示链参与输出协商；
   本机 NVIDIA **一块屏都没接**（`Cannot find any crtc or sizes`），参与即风险（615.78.08 实测两次开机黑屏挂死）。
3. **KWin 光标平面回归**：KWin 把光标平面按 `RA24`（`RGBA8888`）交给 amdgpu DC，被拒
   （`*ERROR* Unsupported screen format RA24`）→ **整个** atomic commit 返回 EINVAL → 桌面起不来。
   与 MST 链路无关（好坏开机的 MST/DSC/LTTPR 指纹完全一致，见 [docs/kwin-ra24-cursor-regression.md](docs/kwin-ra24-cursor-regression.md)）。

## 2. 硬件与拓扑

```
AMD Raphael 核显 (amdgpu, card1, PCI 1002:164E, 0000:11:00.0)
 └── DP-4 口 ──一条 DP 1.4 线──► 显示器 A 的 DP IN
                                ├── 显示器 A 的 DP OUT ──► 显示器 B   (MST 菊花链)
     枚举为 card1-DP-4 (上屏) 与 card1-DP-6 (下屏)，2560×1440@120Hz

NVIDIA RTX 4070 Ti SUPER (0000:01:00.0) —— 不接任何显示器，纯 CUDA 计算
```

- 内核日志佐证：`DM_MST: Differing MST start on aconnector`（MST 拓扑管理器启动）。
- 两块屏均为 **2560×1440@120Hz**；120Hz 是带宽硬约束下的选择，见 [§9](#9-带宽账为什么必须钉-120hz)。

## 3. 核心补丁

与「单线双屏开机稳定」直接相关的补丁共 4 个：

| # | 补丁 | 落点 | 解决什么 |
| --- | --- | --- | --- |
| **①** | **dp-mst-rescue**：开机后检查期望连接器，缺失则对该连接器做 runtime PM 循环（`power/control: on → 原值`），逼 amdgpu 重训练 DP 链路 / 重枚举 MST | [`dp-mst-rescue/`](dp-mst-rescue/)（service + conf + sh） | 「开机只亮一屏」 |
| **②** | **NVIDIA 退出显示链**：显式 `nvidia-drm.modeset=0` | 内核 cmdline（`/etc/default/grub`）+ `/etc/modprobe.d/00-nvidia-drm-modeset.conf` | 黑屏挂死入口（NVIDIA 无屏却注册 KMS） |
| **③** | **SDDM greeter 输出配置钉死**（DP-4 上 / DP-6 下，120Hz，scale 1.3） | `/var/lib/sddm/.config/kwinoutputconfig.json`（样本：[scripts/sddm-kwinoutputconfig.json](scripts/sddm-kwinoutputconfig.json)） | greeter 不再试探链路，降低首帧 modeset 失败率（带宽账见 §9） |
| **④** | **强制软件光标** `KWIN_FORCE_SW_CURSOR=1`（双落点） | `~/.config/environment.d/50-kwin-sw-cursor.conf` + `~/.config/plasma-workspace/env/10-kwin-sw-cursor.sh` | RA24 光标回归 → 桌面概率性进不去 |

> **关键定位**：这些补丁**不在任何驱动文件里**——`rpm -V` 全查 16 个 nvidia 包零差异，无 xorg.conf、
> 无 EDID 覆盖、无自定义服务。补丁活在 **GRUB 内核命令行 + systemd 服务 + 用户环境变量** 三处，
> 驱动升级（akmods 重编）触碰不到它们。

**为什么 ① 是 systemd 服务而不是 udev 规则**：udev 在早期启动触发，那时显示栈还没起来，重枚举无意义；
「开机只亮一屏」要在 `graphical.target` 之后才判断得准。服务只读 `/sys` 状态、只写 `power/control`，
**不碰 DRM master**（Wayland 下 KWin 独占 DRM master，任何 atomic 操作都会 EBUSY）。

## 4. 背景修复（非双屏本体）

同一场开机排障中做的其它改动，**与单线双屏 bug 无直接关系**，仅为完整记录而收录：

| 改动 | 内容 | 与双屏的关系 |
| --- | --- | --- |
| 移除 `rhgb quiet` | BLS 条目 + `/etc/default/grub` | 间接：plymouth 在这条 MST 链上渲染失败时全黑，移除后至少看得见日志 |
| 关 Discover 离线更新 / `dnf-automatic` 改只下载 | `/etc/xdg/discoverrc`、`/etc/dnf/automatic.conf` | 无：防的是「重启进 `system-update.target` 无桌面」的坑 |
| 移除失效的 `vfio-pci` 直通参数 | BLS + `/etc/default/grub` + classic `grub.cfg` | 无：GPU 直通遗留清理，与显示链路无关 |
| GSP 固件随用户态包版本绑定 | 事实记录 | 无：驱动升级回退的边界条件，见 §10 末行 |

对应脚本逐字存档在 [docs/legacy-apply-p1p2p3.sh](docs/legacy-apply-p1p2p3.sh) 与
[docs/legacy-fix-boot-black-screen.sh](docs/legacy-fix-boot-black-screen.sh)（**只留档，不要照跑**）。

## 5. 本机实测状态（2026-10-14 核验）

用 [`scripts/verify-status.sh`](scripts/verify-status.sh) 可在任何装了本补丁集的机器上复测。

| 项 | 实测值 | 判定 |
| --- | --- | --- |
| 内核 | `7.2.10-200.fc44.x86_64` | ✅ |
| NVIDIA 驱动 | `615.78.08`（RTX 4070 Ti SUPER，纯计算） | ✅ |
| 内核命令行 | 含 `nvidia-drm.modeset=0` | ✅ |
| `/sys/module/nvidia_drm/parameters/modeset` | `N` | ✅ 补丁②生效 |
| `/etc/modprobe.d/00-nvidia-drm-modeset.conf` | `options nvidia_drm modeset=0` | ✅ |
| 双屏连接器 | `card1-DP-4` = connected，`card1-DP-6` = connected | ✅ 双屏在位 |
| `card0` 驱动 | `nvidia`（KMS 已关，连接器为空，不参与显示） | ✅ |
| `dp-mst-rescue.service` | enabled；本次开机 `OK: 期望屏全部在位`；近 4 次开机全部 OK | ✅ 补丁①在位 |
| `KWIN_FORCE_SW_CURSOR=1` | 双落点均在位 | ✅ 补丁④在位 |
| 本次开机 `Unsupported screen format RA24` 计数 | `0` | ✅ 补丁④有效 |
| 本次开机 `Atomic modeset commit failed` 计数 | `0` | ✅ |
| 本次开机 `LTTPR` 计数 | `13`（每次开机都有，良性，不具区分度） | ⚪ 已知遗留 |

**未决项（如实记录）**：① `/etc/default/grub` 仍带 `amd_iommu=on`——内核 7.x 已不接受该参数
（开机报 `AMD-Vi: Unknown option - 'on'`），属背景遗留；② SDDM 的 `kwinoutputconfig.json` 为 `sddm`
用户属主（0700 目录），非 root 无法核验其现状。

## 6. 安装

需 root 的部分以 `sudo` 运行；④ 为用户级，无需 root。

**① dp-mst-rescue**

```bash
cd dp-mst-rescue/
sudo install -m 0755 dp-mst-rescue.sh   /usr/local/lib/dp-mst-rescue.sh
sudo install -m 0644 dp-mst-rescue.conf /etc/dp-mst-rescue.conf
sudo install -m 0644 dp-mst-rescue.service /etc/systemd/system/dp-mst-rescue.service
sudo systemctl daemon-reload
sudo systemctl enable dp-mst-rescue.service
```

`/etc/dp-mst-rescue.conf` 每行一个期望连接器（本机为 `card1-DP-4` / `card1-DP-6`）。
**换机器 / 换插口后连接器编号会变**：用 `ls -d /sys/class/drm/card*-DP-*` 配合 `cat .../status`
找出 connected 的两个名字填进去即可，无需改脚本。

**② NVIDIA 退出显示链**

```bash
sudo grubby --update-kernel=ALL --args="nvidia-drm.modeset=0"
sudo sed -i 's/nvidia-drm\.modeset=1/nvidia-drm.modeset=0/' /etc/default/grub   # 若存在
echo 'options nvidia_drm modeset=0' | sudo tee /etc/modprobe.d/00-nvidia-drm-modeset.conf
```

> 代价：NVIDIA 不再直接驱动显示器（显示器在核显上的机器无影响）；CUDA 不依赖 KMS，`/dev/nvidia*` 照旧。

**③ greeter 输出配置**（样本文件按你的连接器名改好后）

```bash
sudo install -d -m 0700 -o sddm -g sddm /var/lib/sddm/.config
sudo install -m 0600 -o sddm -g sddm scripts/sddm-kwinoutputconfig.json /var/lib/sddm/.config/kwinoutputconfig.json
```

**④ 软件光标**（注销重登即生效）

```bash
bash scripts/apply-sw-cursor.sh            # 安装
bash scripts/apply-sw-cursor.sh --status   # 查看
bash scripts/apply-sw-cursor.sh --revert   # 卸载
```

## 7. 验证

```bash
bash scripts/verify-status.sh        # 一键体检（只读，无需 root）

cat /sys/class/drm/card1-DP-4/status /sys/class/drm/card1-DP-6/status   # 期望 connected
journalctl -u dp-mst-rescue -b -o cat        # OK / MISSING→SUCCESS / WARNING 三选一
cat /sys/module/nvidia_drm/parameters/modeset                            # 期望 N
cat /proc/cmdline | grep -o 'nvidia-drm.modeset=[01]'                    # 期望 =0
tr '\0' '\n' < /proc/$(pgrep -x kwin_wayland | head -1)/environ | grep KWIN_FORCE_SW_CURSOR
journalctl -b -k -o cat --no-pager | grep -c 'Unsupported screen format RA24'
journalctl -b -o cat _COMM=kwin_wayland --no-pager | grep -c 'Atomic modeset commit failed'
```

> ⚠️ **测量纪律**：统计必须带字段过滤（内核用 `-k`，kwin 用 `_COMM=kwin_wayland`），
> 否则自动化进程的单行超长命令行会被算进计数（详见 [docs/kwin-ra24-cursor-regression.md §7](docs/kwin-ra24-cursor-regression.md)）。

**判据**：连续 3 次重启都双屏全亮且能进桌面、上述计数为 0，才算修复。

## 8. 卸载 / 回滚

```bash
# ①
sudo systemctl disable --now dp-mst-rescue.service
sudo rm /etc/systemd/system/dp-mst-rescue.service /etc/dp-mst-rescue.conf /usr/local/lib/dp-mst-rescue.sh
sudo systemctl daemon-reload
# ②
sudo grubby --update-kernel=ALL --remove-args="nvidia-drm.modeset=0"
sudo rm /etc/modprobe.d/00-nvidia-drm-modeset.conf
# ③
sudo rm /var/lib/sddm/.config/kwinoutputconfig.json
# ④
bash scripts/apply-sw-cursor.sh --revert
```

## 9. 带宽账：为什么必须钉 120Hz

| 项 | 数值 |
| --- | --- |
| 单屏 2560×1440@180Hz | ≈ 16.4 Gbps |
| 双屏合计 @180Hz | ≈ **32.8 Gbps** |
| DP 1.4（HBR3 4 lane）有效载荷 | ≈ **25.9 Gbps** |
| 双屏 @144Hz | ≈ 26.7 Gbps —— 仍超上限，只能靠 DSC 硬压 |
| 双屏 @120Hz | ≈ **21.9 Gbps** —— 落回 DP1.4 之内，很可能连 DSC 都不需要 |

超限就依赖 DSC，而 DSC 一上来 MST 时隙载荷分配更易失败（`MST_DSC` + `allocate_mst_payload` WARNING +
`DM_MST` 反复重启）→ 黑屏。**这就是钉 120Hz 的原因，不是省电。**

运行时改刷新率（连接器名以当次开机为准）：

```bash
kscreen-doctor output.DP-4.mode.2560x1440@120 output.DP-6.mode.2560x1440@120
# 仍黑屏再退一档：
kscreen-doctor output.DP-4.mode.2560x1440@100 output.DP-6.mode.2560x1440@100
```

显示器 OSD 侧（不用换线）：DP 版本固定 **1.4**；DSC 开/关各试一轮；关 FreeSync/Adaptive-Sync、关 HDR、
色深固定 8bit；确认走 **MST** 而非显示器内部 PBP。固件侧：主板 BIOS（AGESA）与显示器固件——
MST/LTTPR 的修复大多落在这两处。

## 10. 故障排查

| 现象 | 排查 |
| --- | --- |
| 开机只亮一屏 | `journalctl -u dp-mst-rescue -b`：`MISSING → SUCCESS` = 保险救回；`WARNING` = 力度不够，加大 `DP_MST_SETTLE=15`，终极手段（会黑屏一下）：对核显 PCI 设备 unbind/bind 强制整卡重初始化（见 [dp-mst-rescue/README.md](dp-mst-rescue/README.md)） |
| 连接器改名 | 服务日志提示 `sysfs 里找不到` → 只改 `/etc/dp-mst-rescue.conf`，脚本不动 |
| greeter 稳、桌面进不去 | `journalctl -b -k -o cat \| grep -c 'Unsupported screen format RA24'` 非 0 → 上补丁④；备选：`KWIN_DRM_NO_AMS=1`、`KWIN_DRM_NO_DIRECT_SCANOUT=1`、换 X11 会话、等 kwin 上游修复 |
| 全黑无 TTY | 先别急着重启；`Ctrl+Alt+F3` 切 TTY；`ls -l /system-update` 查离线更新；确认 `nvidia-drm.modeset=0` 在位 |
| 升级 nvidia 驱动后黑屏 | 已知 615.78.08 有显示回归（见 §11 引用）；GSP 固件随用户态包版本绑定——**升级会删旧固件，退回旧内核 ≠ 退回旧 CUDA**，回退需整套（用户态+固件+kmod） |

## 11. 引用的技术与仓库

**上游技术 / 组件**

| 技术 | 用途 | 出处 |
| --- | --- | --- |
| Linux 内核 `amdgpu` DM_MST / DP 链路训练 / LTTPR | 被修复对象；`power/control` 重探测机制 | [kernel.org](https://www.kernel.org/) · [DRM 文档](https://docs.kernel.org/gpu/amdgpu/index.html) |
| DisplayPort 1.4 MST（菊花链） | 单线双屏的规范基础 | [VESA DisplayPort](https://www.displayport.org/) |
| systemd（oneshot 服务 / `graphical.target` 排序 / BLS） | 补丁①载体 | [systemd](https://systemd.io/) · [Fedora BLS 变更页](https://fedoraproject.org/wiki/Changes/Block_System_Launcher_Booting_for_Fedora) |
| KDE Plasma **KWin**（Wayland）`KWIN_FORCE_SW_CURSOR` 等环境变量 | 补丁④对策 | [KWin 环境变量 Wiki](https://invent.kde.org/plasma/kwin/-/wikis/Environment-Variables) · [kwin 源码仓库](https://invent.kde.org/plasma/kwin) |
| **SDDM**（greeter） | 补丁③落点 | [SDDM 仓库](https://github.com/sddm/sddm) |
| KDE **kscreen** `kscreen-doctor` | 刷新率运行时调整 | [kscreen 仓库](https://invent.kde.org/kde/kscreen) |
| GRUB / `grubby` | 内核参数落点 | [GNU GRUB](https://www.gnu.org/software/grub/) |
| rpmfusion **akmod-nvidia**（Fedora 的 nvidia 打包机制） | 驱动升级与 kmod 重编（补丁不受其影响的判定依据） | [RPM Fusion](https://rpmfusion.org/) |

**外部佐证（社区报告，均为外部不可信内容，仅作线索）**

| 引用 | 与本补丁的关系 |
| --- | --- |
| [Arch Linux 内核补丁：设置 `nvidia-drm.modeset=1` 时跳过 simpledrm](https://github.com/archlinux/linux/commit/3720e1b0eb7d814345b25541997e63b50b897749) | 佐证「nvidia-drm 与 simpledrm 冲突 → 启动输出/TTY 全黑」机制 |
| [NVIDIA 论坛：nvidia 驱动与 simpledrm 不兼容，boot/TTY 全黑](https://forums.developer.nvidia.com/t/nvidia-driver-isnt-compatible-with-simpledrm-so-boot-output-and-ttys-are-blank/238007?page=2) | 同上 |
| [NVIDIA 论坛：615.78.08 显示回归（Thunderbolt 坞无显示）](https://forums.developer.nvidia.com/t/615-78-08-regression-no-display-detected-through-thunderbolt-4-dock-610-57-04-works/385494) | 佐证 615.78.08 存在显示回归 |
| [basecamp/omarchy#6518：AMD+NVIDIA+Plymouth+密码 greeter → 开机黑屏挂死](https://github.com/basecamp/omarchy/issues/6518) | 与本机黑屏症状逐字吻合 |
| [PikaOS Wiki：KWin Bug — Unsupported Screen Format RA24 (AMD GPUs)](https://wiki.pika-os.com/en/kwin-ra24-freezing-workaround) | 补丁④（软光标）的社区出处 |
| [CachyOS 论坛：KWin RA24 回归 / atomic modeset failure](https://discuss.cachyos.org/t/kwin-regression-unsupported-screen-format-ra24-atomic-modeset-failure-when-changing-displays/34696) | RA24 回归的版本证据（6.7.4-1.1 正常 / 6.7.4-5.1 起问题） |
| [CachyOS 论坛：`/etc/environment` 加 `KWIN_FORCE_SW_CURSOR=1`](https://discuss.cachyos.org/t/artifacts-corruption-on-desktop-background-wallpaper/34988) | 补丁④落点先例 |

**仓库内文件**

| 文件 | 说明 |
| --- | --- |
| [`README.en.md`](README.en.md) | 主页英文版（逐节对应） |
| [`CHANGELOG.md`](CHANGELOG.md) / [`CHANGELOG.en.md`](CHANGELOG.en.md) | 补丁时间线（中 / 英） |
| [`dp-mst-rescue/`](dp-mst-rescue/) | 核心补丁①本体（service / conf / sh），含[英文版](dp-mst-rescue/README.en.md) |
| [`scripts/apply-sw-cursor.sh`](scripts/apply-sw-cursor.sh) | 核心补丁④安装 / 查询 / 回滚 |
| [`scripts/sddm-kwinoutputconfig.json`](scripts/sddm-kwinoutputconfig.json) | 核心补丁③的 greeter 输出配置样本 |
| [`scripts/verify-status.sh`](scripts/verify-status.sh) | 只读体检脚本 |
| [`docs/display-link-notes.md`](docs/display-link-notes.md) / [`.en.md`](docs/display-link-notes.en.md) | 显示链路笔记（带宽账 / OSD / 固件 / 自救） |
| [`docs/kwin-ra24-cursor-regression.md`](docs/kwin-ra24-cursor-regression.md) / [`.en.md`](docs/kwin-ra24-cursor-regression.en.md) | RA24 完整诊断报告（证据表 / 根因链 / 备选方案） |
| [`docs/legacy-apply-p1p2p3.sh`](docs/legacy-apply-p1p2p3.sh) | 背景修复脚本存档（含核心补丁③的当年一次性执行版） |
| [`docs/legacy-fix-boot-black-screen.sh`](docs/legacy-fix-boot-black-screen.sh) | 更早的旧方案逐字存档（定性已过时） |

## 12. 免责声明

- 本仓库记录的是**特定硬件组合**（AMD Raphael 核显 + DP1.4 MST 双 1440p + NVIDIA 无屏独显 + Fedora + KDE Wayland）
  上验证过的补丁。换硬件/发行版请自行核对判据，勿直接照搬。
- 引用的外部内容（论坛/Wiki/issue）为**不可信外部数据**，仅作线索，不构成对上游的承诺。
- 涉及 root 的操作均有备份目录；删除前逐项核对绝对路径。
