# dp-mst-rescue —— AMD DP MST 双屏开机保险 / Boot-time rescue for AMD DP MST dual monitors

> 核心补丁①。入口：本文件。安装需 root。仓库总入口：[`../README.md`](../README.md)。
> **EN — Core patch ①. Installation needs root. Repository entry point: [`../README.md`](../README.md).**

## 背景 / Context

**中文**
- 两块 2560×1440 屏走 **DP MST**，挂在 **AMD Raphael 核显 `card1`** 的 `card1-DP-4` / `card1-DP-6`。
- `card0` 是 NVIDIA 独显，没接任何屏。
- 现象：拼接模式正常；分屏模式偶尔只亮一屏，**开机时 100% 只亮一屏**。
- 第一道保险：KWin 的 `~/.config/kwinoutputconfig.json`（屏被识别后自动套用正确布局）。
- 本服务是第二道保险：**内核/驱动层**——开机后若某块 MST 屏没被枚举出来，强制 AMDGPU 重新训练 DP 链路 / 重枚举 MST。

**EN** — Two 2560×1440 monitors ride **DP MST** on the **AMD Raphael iGPU `card1`** as `card1-DP-4` / `card1-DP-6`; `card0` is the NVIDIA dGPU with no monitor attached. Extended-desktop mode occasionally lit only one monitor, and at boot it was 100% one-monitor. The first safety net is KWin's `~/.config/kwinoutputconfig.json` (applies the correct layout once outputs are detected). This service is the second net, at the kernel/driver level: if an MST monitor is not enumerated after boot, it forces amdgpu to re-train the DP link / re-enumerate MST.

## 为什么用 systemd 服务而不是纯 udev 规则 / Why a systemd service, not a udev rule

**中文**
- udev 规则在**早期启动**就触发，那时显示栈（KWin/DP 链路训练）还没起来，重枚举没意义。
- 「开机只亮一屏」是**显示栈起来之后**才判断得准的，所以放在 `graphical.target` 之后跑最可靠。

**EN** — udev rules fire early in boot, before the display stack (KWin, DP link training) exists, so re-enumeration at that point is meaningless. The "one monitor missing" verdict is only reliable once the display stack is up, hence `graphical.target` ordering.

## 工作原理 / How it works

**中文**
1. `graphical.target` 起来后启动（oneshot）。
2. 等 `DP_MST_SETTLE`（默认 8s）让显示栈稳定。
3. 读 `/etc/dp-mst-rescue.conf` 里期望的连接器，逐个查 `/sys/class/drm/<conn>/status`。
4. 全在位 → 记日志退出（正常情况，KWin 负责布局）。
5. 有缺失 → 对缺失连接器写 `power/control`：`on` → 原值（runtime PM 循环），逼驱动重探测 DP/MST；等 5s 复查。
6. 全程写 journal，前缀 `dp-mst-rescue:`。

> 只读 `/sys` 状态、只写 `power/control`，**不碰 DRM master**——Wayland 下 KWin 独占 DRM master，任何 atomic 操作都会 EBUSY，所以这条路被刻意避开。

**EN** — Starts as a oneshot after `graphical.target`; waits `DP_MST_SETTLE` (default 8 s) for the display stack to settle; reads the expected connectors from `/etc/dp-mst-rescue.conf` and checks each `/sys/class/drm/<conn>/status`. All present → log and exit (normal case, KWin handles layout). Any missing → write `power/control`: `on` → previous value (a runtime-PM cycle) to force the driver to re-probe DP/MST, then re-check after 5 s. Everything is logged to the journal with the `dp-mst-rescue:` prefix. It only reads `/sys` state and writes `power/control`, **never touching the DRM master** — on Wayland KWin owns it exclusively and any atomic operation would return EBUSY, so that path is deliberately avoided.

## 安装（需要 root）/ Installation (root required)

```bash
cd dp-mst-rescue/

sudo install -m 0755 dp-mst-rescue.sh /usr/local/lib/dp-mst-rescue.sh
sudo install -m 0644 dp-mst-rescue.conf /etc/dp-mst-rescue.conf
sudo install -m 0644 dp-mst-rescue.service /etc/systemd/system/dp-mst-rescue.service

sudo systemctl daemon-reload
sudo systemctl enable dp-mst-rescue.service
```

## 手动测试（不重启，立刻验证逻辑）/ Manual test (no reboot)

**中文** — 两块屏都在位时，正常跑应打印 `OK: 期望屏全部在位`：

**EN** — With both monitors present, a normal run prints `OK: 期望屏全部在位` ("all expected monitors present"):

```bash
DP_MST_SETTLE=0 sudo /usr/local/lib/dp-mst-rescue.sh
```

**中文** — 想**故意触发重探测路径**（确认 re-probe 真的会执行、会不会掉线再回来）：临时把配置里一个连接器改成不存在的名字，或直接对某连接器手动跑 re-probe：

**EN** — To deliberately exercise the re-probe path (verify it runs, and that a monitor drops and comes back): temporarily put a non-existent connector name in the config, or run the cycle by hand:

```bash
# 看当前状态 / current state
cat /sys/class/drm/card1-DP-4/status /sys/class/drm/card1-DP-6/status
# 手动对 DP-6 做一次 runtime PM 循环（需要 root）/ manual runtime-PM cycle on DP-6 (root)
echo on   > /sys/class/drm/card1-DP-6/power/control; sleep 1
echo auto > /sys/class/drm/card1-DP-6/power/control; sleep 2
cat /sys/class/drm/card1-DP-6/status
```

## 验证开机效果（重启后）/ Verifying after a reboot

```bash
journalctl -u dp-mst-rescue -b          # 本次启动日志 / this boot's log
ls /sys/class/drm/card1-DP-4/status /sys/class/drm/card1-DP-6/status
```

**中文 / EN**
- `OK: 期望屏全部在位` → 正常，没触发保险 / normal, rescue not needed.
- `MISSING ... SUCCESS: 全部恢复` → 保险生效，救回了一块屏 / rescue fired and recovered a monitor.
- `WARNING: 重探测后仍缺失` → runtime PM 循环没够力，见下节 / the PM cycle was not strong enough, see next section.

## 如果 runtime PM 循环不够力（仍只亮一屏）/ If the PM cycle is not enough

**中文** — 按从温和到激进：

**EN** — From gentle to aggressive:

1. 加大等待 / raise the settle time：`DP_MST_SETTLE=15`（在 `.service` 的 `ExecStart` 前加环境变量，或改脚本默认值）。
2. 看内核日志定位 / inspect kernel logs：`journalctl -k | grep -iE 'amdgpu|mst|dp|aux'`。
3. 终极手段（会黑屏一下，慎用）/ last resort, causes a brief blackout：重绑 amdgpu PCI 设备强制整卡重新初始化 / rebind the amdgpu PCI device to force full re-initialization —
   ```bash
   sudo bash -c 'echo 0000:11:00.0 > /sys/bus/pci/drivers/amdgpu/unbind; sleep 2; echo 0000:11:00.0 > /sys/bus/pci/drivers/amdgpu/bind'
   ```
   这会让该卡上所有显示短暂消失再恢复，确认有效后再考虑写进脚本做最后兜底。
   All displays on that card vanish briefly and come back; only bake this into the script as a final fallback after confirming it works.

## 连接器改名了怎么办 / If connector names change

**中文** — 开机编号若变化（日志会提示 `sysfs 里找不到`），改 `/etc/dp-mst-rescue.conf` 里的名字即可，无需改脚本。当前实际名字可用 `ls -d /sys/class/drm/card1-DP-*` 配合 `cat .../status` 确认哪两个是 connected。

**EN** — Connector numbering can change between boots (the log says the name was not found in sysfs). Edit `/etc/dp-mst-rescue.conf` only; the script needs no change. Find the current names with `ls -d /sys/class/drm/card1-DP-*` plus `cat .../status` and keep the two that report `connected`.

## 卸载 / Uninstall

```bash
sudo systemctl disable --now dp-mst-rescue.service
sudo rm /etc/systemd/system/dp-mst-rescue.service /etc/dp-mst-rescue.conf /usr/local/lib/dp-mst-rescue.sh
sudo systemctl daemon-reload
```
