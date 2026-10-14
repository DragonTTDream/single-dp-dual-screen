# CHANGELOG — 单线双屏补丁时间线 / Patch Timeline

> 全部结论可追到取证（journalctl / audit / `rpm -V` / 逐行日志），原始档案见 `docs/` 与 README §11。
> **EN — Every entry below is traceable to log evidence (journalctl / audit / `rpm -V` / line-by-line logs); raw archives live in `docs/` and README §11. Labels: 核心 CORE = part of the dual-screen fix · 背景 BACKGROUND = done in the same campaign, not part of the dual-screen fix.**

## 2026-09-24 — 核心① dp-mst-rescue 安装 / Core ① installed

**中文**
- 现象：开机 100% 只亮一屏（MST 枚举不完整）。
- 落点：`/etc/systemd/system/dp-mst-rescue.service`（enabled）+ `/etc/dp-mst-rescue.conf` + `/usr/local/lib/dp-mst-rescue.sh`。
- 机制：`graphical.target` 后检查期望连接器；缺失 → 对该连接器做 runtime PM 循环（`power/control: on → 原值`）逼 amdgpu 重训练 DP / 重枚举 MST；不碰 DRM master。

**EN** — Boot lit only one of the two monitors, 100% reproducible (incomplete MST enumeration). Installed the oneshot service + config + script; after `graphical.target` it checks the expected connectors and cycles runtime PM on any missing one to force amdgpu to re-train / re-enumerate, never touching the DRM master.

## 2026-09-27 — 开机黑屏修复（核心③ + 背景）/ Boot black-screen fix (Core ③ + background)

**中文**
- 根因：DP 链路训练不稳定（LTTPR 误读每次开机都有）+ 首次 modeset 时 amdgpu MST payload 分配竞态 → KWin atomic commit EINVAL。
- **核心③**：SDDM greeter 输出配置钉死（DP-4 上 / DP-6 下，120Hz，scale 1.3）。
- 背景：移除 `rhgb quiet`（grubby 对 BLS 无效，直接改 `/boot/loader/entries/*.conf`）；关 Discover 离线更新；`dnf-automatic` 改只下载；移除失效的 `vfio-pci.ids` / `rd.driver.pre=vfio-pci` 参数。
- 同期：内核升 7.2.7-200 并设默认；`dracut --force` 清除烤入的 `rd.driver.pre=vfio_pci`。
- 结果：开机黑屏修复确认。

**EN** — Root cause: unstable DP link training (LTTPR misread on every boot) + amdgpu MST payload allocation race at the first modeset → KWin atomic commit `EINVAL`. **Core ③**: pinned the SDDM greeter output config (DP-4 top / DP-6 bottom, 120Hz, scale 1.3). Background: removed `rhgb quiet` (grubby does not touch BLS — edit `/boot/loader/entries/*.conf` directly), disabled Discover offline updates, made `dnf-automatic` download-only, dropped the dead `vfio-pci.ids` / `rd.driver.pre=vfio-pci` args. Kernel updated to 7.2.7-200 and set default; `dracut --force` removed the baked-in `rd.driver.pre=vfio_pci`. Boot black screen confirmed fixed.

## 2026-09-29 — 核心④ 软光标（RA24 回归）/ Core ④ software cursor (RA24 regression)

**中文**
- 新暴露：greeter 稳、桌面概率性进不去（失败率约 2/3）。
- 取证：失败开机 `Unsupported screen format RA24` 1024–1235 次 + `Atomic modeset commit failed` 36–43 次；成功开机为 0。MST/DSC/LTTPR 指纹好坏开机完全一致 → **与 MST 链路无关**（此前「MST 训练未消除」的归因作废并就地更正）。
- 根因：KWin 光标平面按 `RA24`(RGBA8888) 交给 amdgpu DC 被拒 → 整个 atomic commit EINVAL。
- 对策：`KWIN_FORCE_SW_CURSOR=1` 双落点（environment.d + plasma env）。判据：连续 3 次重启进桌面 + 三条计数为 0。

**EN** — Newly exposed: greeter stable, desktop startup random (~2/3 failure). Evidence: failing boots logged 1024–1235 × `Unsupported screen format RA24` and 36–43 × `Atomic modeset commit failed`; successful boots logged 0. MST/DSC/LTTPR fingerprints identical on good and bad boots → **not an MST link problem** (the earlier "MST training not fully eliminated" attribution was retracted on the spot). Root cause: KWin hands the cursor plane over as `RA24` (RGBA8888), amdgpu DC rejects it, the whole atomic commit returns `EINVAL`. Fix: `KWIN_FORCE_SW_CURSOR=1` at two drop points. Acceptance: 3 consecutive reboots reaching the desktop with all three counters at 0.

## 2026-10-14 — 驱动升级黑屏事故与核心② / Driver-upgrade black screen and Core ②

**中文**
- 背景：nvidia 615.71.09 → 615.78.08 升级成功（rpmfusion 元数据冻结问题一并修复）。
- 事故：7.2.10 + 615.78.08 重启**黑屏挂死 2/2 次**，退回旧内核才进来。
- 取证推翻「nvidia-drm 抢 card0」推断（DRM 拓扑逐行一致）；真差异＝驱动版本。
- 关键边界：**GSP 固件随用户态包版本绑定**——升级删除旧固件 → 「退回旧内核」救回登录界面但**永远无 CUDA**；CUDA 只能在 7.2.10 + 615.78.08 上跑。
- 拓扑实锤：两块屏都在核显 `card1-DP-4`/`card1-DP-6`（MST），NVIDIA 侧 `Cannot find any crtc or sizes`——**NVIDIA 一块屏都没接**，`nvidia-drm.modeset=1` 对显示毫无用处，却是黑屏入口。
- 「删 cmdline 参数」被实测**证伪为空操作**：615.78.08 默认 modeset=1，删参数后 `modeset=Y`、card0 仍归 nvidia、拓扑逐行相同。
- **核心②正式形态**：显式 `nvidia-drm.modeset=0`，双落点（GRUB cmdline + `/etc/modprobe.d/00-nvidia-drm-modeset.conf`）。
- 验证：`modeset=N`、card0 连接器为空、CUDA/双屏/服务全正常，7.2.10 连续正常进入。
- 附带（背景）：vfio 遗留清理（`/etc/modprobe.d/vfio.conf`、`/etc/dracut.conf.d/vfio.conf` 删除 + initramfs 重建 −247844 B）→ 开机不再抢注显卡。

**EN** — NVIDIA driver 615.71.09 → 615.78.08 upgraded (an rpmfusion metadata freeze fixed along the way). Then 7.2.10 + 615.78.08 hung black on reboot **2 out of 2 times**; only booting the old kernel got in. Evidence refuted the "nvidia-drm steals card0" theory (DRM topology line-for-line identical) — the real variable was the driver version. Key boundary: **GSP firmware is version-bound to the userspace package**, so upgrading deletes the old firmware and "booting the old kernel" restores the login screen at the price of **no CUDA, permanently**; CUDA runs only on 7.2.10 + 615.78.08. Topology proof: both monitors sit on the iGPU (`card1-DP-4`/`card1-DP-6`, MST) while NVIDIA reports `Cannot find any crtc or sizes` — **no monitor attached to NVIDIA at all**, so `nvidia-drm.modeset=1` buys nothing for displays yet is the black-screen entry point. "Just delete the cmdline arg" was **falsified as a no-op**: 615.78.08 defaults to modeset=1, and after deletion `modeset=Y`, card0 still nvidia-owned, topology identical. **Core ② final form**: explicit `nvidia-drm.modeset=0` at two drop points (GRUB cmdline + modprobe.d). Verified: `modeset=N`, card0 connectors empty, CUDA / dual screens / rescue service all normal, 7.2.10 boots cleanly. Background side-effect: vfio leftovers removed (`/etc/modprobe.d/vfio.conf`, `/etc/dracut.conf.d/vfio.conf` deleted + initramfs rebuilt, −247844 B) → the boot no longer claims the GPU.

## 2026-10-14 20:37 — 全体系复核（README 状态表的来源）/ Full re-verification (source of the README status table)

**中文** — 双屏 connected；`modeset=N`；dp-mst-rescue 近 4 次开机全部 `OK`；软光标双落点在位；RA24=0、Atomic=0；`lsmod | grep vfio` 为空。未决：`/etc/default/grub` 仍带内核已不认的 `amd_iommu=on`（清理脚本已备未跑）；SDDM 输出配置为 sddm 属主，非 root 无法核验。

**EN** — Both connectors `connected`; `modeset=N`; dp-mst-rescue `OK` on the last 4 boots; software-cursor drop points present; RA24 = 0, atomic failures = 0; no vfio modules loaded. Open: a dead `amd_iommu=on` remains in `/etc/default/grub` (cleanup script prepared, not run); the sddm-owned greeter config cannot be verified as non-root.
