# dp-mst-rescue —— AMD DP MST 双屏开机双保险

> **适配说明**：本文由源机器档案并入本仓库（2026-10-14），路径已按仓库结构修正。

> 入口：本文件。安装需 root。仓库总入口：[`../README.md`](../README.md)。

## 背景（你这台机器的实际情况）
- 两块 Sculptor 屏走 **DP MST**，挂在 **AMD Raphael 核显 `card1`** 的 `card1-DP-4` / `card1-DP-6`。
- `card0` 是 NVIDIA RTX 4070 Ti SUPER（独显，没接屏；源机器历史上曾带 `vfio-pci.ids=10de:2705` 直通参数，后已移除，见仓库总 README 的 P3）。
- 现象：拼接模式正常；分屏模式偶尔只亮一屏，**开机时 100% 只亮一屏**。
- 已有第一道保险：KWin 的 `~/.config/kwinoutputconfig.json`（屏被识别后自动套用正确布局）。
- 本脚本是第二道保险：**内核/驱动层**——开机后若某块 MST 屏没被枚举出来，强制 AMDGPU 重新训练 DP 链路 / 重枚举 MST。

## 为什么用 systemd 服务而不是纯 udev 规则
- udev 规则在**早期启动**就触发，那时显示栈（KWin/DP 链路训练）还没起来，重枚举没意义。
- "开机只亮一屏"是**显示栈起来之后**才判断得准的，所以放在 `graphical.target` 之后跑最可靠。
- 纯 udev 规则救不了这个开机场景；本方案用 systemd 服务做主保险。

## 工作原理
1. `graphical.target` 起来后启动（oneshot）。
2. 等 `DP_MST_SETTLE`（默认 8s）让显示栈稳定。
3. 读 `/etc/dp-mst-rescue.conf` 里期望的连接器，逐个查 `/sys/class/drm/<conn>/status`。
4. 全在位 → 记日志退出（正常情况，KWin 负责布局）。
5. 有缺失 → 对缺失连接器写 `power/control`：`on` → 原值（runtime PM 循环），逼驱动重探测 DP/MST；等 5s 复查。
6. 全程写 journal，前缀 `dp-mst-rescue:`。

> 只读 `/sys` 状态、只写 `power/control`，**不碰 DRM master**——Wayland 下 KWin 独占 DRM master，任何 atomic 操作都会 EBUSY，所以这条路被刻意避开。

## 安装（需要 root）

> 源机器已安装并 enabled：`/etc/systemd/system/dp-mst-rescue.service`、`/etc/dp-mst-rescue.conf`、`/usr/local/lib/dp-mst-rescue.sh`。以下命令仅在新机器复现 / 重装时使用。
```bash
cd dp-mst-rescue/

sudo install -m 0755 dp-mst-rescue.sh /usr/local/lib/dp-mst-rescue.sh
sudo install -m 0644 dp-mst-rescue.conf /etc/dp-mst-rescue.conf
sudo install -m 0644 dp-mst-rescue.service /etc/systemd/system/dp-mst-rescue.service

sudo systemctl daemon-reload
sudo systemctl enable dp-mst-rescue.service
```

## 手动测试（不重启，立刻验证逻辑）
两块屏现在都在位，正常跑应该打印 `OK: 期望屏全部在位`：
```bash
DP_MST_SETTLE=0 sudo /usr/local/lib/dp-mst-rescue.sh
```
想**故意触发重探测路径**（确认 re-probe 真的会执行、会不会掉线再回来）：
临时把配置里一个连接器改成不存在的名字，或直接对某连接器手动跑 re-probe：
```bash
# 看当前状态
cat /sys/class/drm/card1-DP-4/status /sys/class/drm/card1-DP-6/status
# 手动对 DP-6 做一次 runtime PM 循环（需要 root），观察它是否掉线再恢复
echo on   > /sys/class/drm/card1-DP-6/power/control; sleep 1
echo auto > /sys/class/drm/card1-DP-6/power/control; sleep 2
cat /sys/class/drm/card1-DP-6/status
```

## 验证开机效果（重启后）
```bash
journalctl -u dp-mst-rescue -b          # 看本次启动的日志
ls /sys/class/drm/card1-DP-4/status /sys/class/drm/card1-DP-6/status
```
- 看到 `OK: 期望屏全部在位` → 正常，没触发保险。
- 看到 `MISSING ... SUCCESS: 全部恢复` → 保险生效，救回了一块屏。
- 看到 `WARNING: 重探测后仍缺失` → runtime PM 循环没够力，见下方"如果不够力"。

## 如果 runtime PM 循环不够力（仍只亮一屏）
按从温和到激进：
1. 加大等待：`DP_MST_SETTLE=15`（在 .service 的 ExecStart 前加环境变量，或改脚本默认值）。
2. 看内核日志定位：`journalctl -k | grep -iE 'amdgpu|mst|dp|aux'`。
3. 终极手段（会黑屏一下，慎用）：重绑 amdgpu PCI 设备强制整卡重新初始化——
   ```bash
   sudo bash -c 'echo 0000:11:00.0 > /sys/bus/pci/drivers/amdgpu/unbind; sleep 2; echo 0000:11:00.0 > /sys/bus/pci/drivers/amdgpu/bind'
   ```
   这会让 card1 上所有显示短暂消失再恢复，确认有效后再考虑写进脚本做最后兜底。

## 连接器改名了怎么办
开机编号若变化（日志会提示 `sysfs 里找不到`），改 `/etc/dp-mst-rescue.conf` 里的名字即可，无需改脚本。
当前实际名字可用：`ls -d /sys/class/drm/card1-DP-*` 配合 `cat .../status` 确认哪两个是 connected。

## 卸载
```bash
sudo systemctl disable --now dp-mst-rescue.service
sudo rm /etc/systemd/system/dp-mst-rescue.service /etc/dp-mst-rescue.conf /usr/local/lib/dp-mst-rescue.sh
sudo systemctl daemon-reload
```
