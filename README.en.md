# Single-Cable Dual-Monitor (DP 1.4 MST) Boot-Fix Patch Set

[简体中文](README.md) · **English**

> **One DisplayPort cable → MST daisy chain → two 2560×1440 monitors**, driven by an AMD Raphael iGPU;
> the NVIDIA dGPU drives no display at all and is used for compute only.
> This repository collects the core patches and the full diagnosis records that make this topology light
> up both monitors and reach the desktop reliably on every boot.

[![Fedora](https://img.shields.io/badge/Fedora-44-blue)](https://fedoraproject.org/)
[![KDE Plasma](https://img.shields.io/badge/KDE_Plasma-Wayland-blueviolet)](https://kde.org/plasma-desktop/)
[![Kernel](https://img.shields.io/badge/kernel-7.2.10-informational)](https://kernel.org/)
[![nvidia](https://img.shields.io/badge/nvidia-615.78.08-76B900)](https://www.nvidia.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> Full Chinese text: [README.md](README.md) (section-by-section counterpart, not a summary) · Timeline: [CHANGELOG.md](CHANGELOG.md) / [CHANGELOG.en.md](CHANGELOG.en.md)

## Table of Contents

1. [The problem](#1-the-problem)
2. [Hardware & topology](#2-hardware--topology)
3. [Core patches](#3-core-patches)
4. [Background fixes (not part of the dual-screen fix)](#4-background-fixes-not-part-of-the-dual-screen-fix)
5. [Verified status on the source machine (2026-10-14)](#5-verified-status-on-the-source-machine-2026-10-14)
6. [Installation](#6-installation)
7. [Verification](#7-verification)
8. [Uninstall & rollback](#8-uninstall--rollback)
9. [Bandwidth budget: why 120Hz is mandatory](#9-bandwidth-budget-why-120hz-is-mandatory)
10. [Troubleshooting](#10-troubleshooting)
11. [Referenced technologies & repositories](#11-referenced-technologies--repositories)
12. [Disclaimer](#12-disclaimer)

---

## 1. The problem

| Symptom | Behaviour |
| --- | --- |
| Black screen at boot | Probabilistic total blackout after login, no TTY, forced power-button shutdown |
| Only one monitor lights up at boot | Incomplete MST enumeration — only one of the two monitors appears (once 100% reproducible at boot) |
| Desktop fails to start at random | SDDM greeter is fine, the Plasma session goes black (~2/3 failure rate) |

Three root causes, each proven from logs (evidence chain in [docs/](docs/)):

1. **Unstable DP link training**: every boot the kernel logs `LTTPR count is nonzero but invalid lane count`
   + `lttpr_caps phy_repeater_cnt is 0x0, forcing it to 0x80`; at the first real modeset amdgpu hits an
   **MST payload allocation race** → KWin `Atomic modeset commit failed! (EINVAL)`.
2. **The NVIDIA driver registers a KMS device it never uses**: with `nvidia-drm.modeset=1` NVIDIA joins the
   display chain and takes part in output negotiation. This machine has **no monitor attached to NVIDIA**
   (`Cannot find any crtc or sizes`), so its participation is pure risk (615.78.08 hung black on 2 of 2 boots).
3. **KWin cursor-plane regression**: KWin hands the cursor plane over as `RA24` (`RGBA8888`), amdgpu DC rejects
   it (`*ERROR* Unsupported screen format RA24`) → the **entire** atomic commit returns EINVAL → the desktop
   never finishes initializing. This is unrelated to the MST link (MST/DSC/LTTPR fingerprints are identical on
   good and bad boots — see [docs/kwin-ra24-cursor-regression.en.md](docs/kwin-ra24-cursor-regression.en.md)).

## 2. Hardware & topology

```
AMD Raphael iGPU (amdgpu, card1, PCI 1002:164E, 0000:11:00.0)
 └── DP-4 port ──one DP 1.4 cable──► monitor A DP IN
                                    ├── monitor A DP OUT ──► monitor B   (MST daisy chain)
     enumerated as card1-DP-4 (top) and card1-DP-6 (bottom), 2560×1440@120Hz

NVIDIA RTX 4070 Ti SUPER (0000:01:00.0) — no monitor attached, CUDA only
```

- Kernel evidence: `DM_MST: Differing MST start on aconnector` (the MST topology manager starts).
- Both monitors run **2560×1440@120Hz**; 120Hz is dictated by the bandwidth budget, see [§9](#9-bandwidth-budget-why-120hz-is-mandatory).

## 3. Core patches

Four patches are directly about dual-screen boot stability:

| # | Patch | Where it lands | What it fixes |
| --- | --- | --- | --- |
| **①** | **dp-mst-rescue**: after boot, check the expected connectors; for any missing one, cycle its runtime power management (`power/control: on → previous`) to force amdgpu to re-train the DP link / re-enumerate MST | [`dp-mst-rescue/`](dp-mst-rescue/) (service + conf + sh) | "only one monitor lights up at boot" |
| **②** | **NVIDIA out of the display chain**: explicit `nvidia-drm.modeset=0` | kernel cmdline (`/etc/default/grub`) + `/etc/modprobe.d/00-nvidia-drm-modeset.conf` | the boot-hang entry point (a display-less GPU registering KMS) |
| **③** | **SDDM greeter output config pinned** (DP-4 top / DP-6 bottom, 120Hz, scale 1.3) | `/var/lib/sddm/.config/kwinoutputconfig.json` (sample: [scripts/sddm-kwinoutputconfig.json](scripts/sddm-kwinoutputconfig.json)) | the greeter stops probing the link, lowering first-modeset failure rate (bandwidth budget in §9) |
| **④** | **Force software cursor** `KWIN_FORCE_SW_CURSOR=1` (two drop points) | `~/.config/environment.d/50-kwin-sw-cursor.conf` + `~/.config/plasma-workspace/env/10-kwin-sw-cursor.sh` | RA24 cursor regression → random desktop startup |

> **Key finding**: none of these live inside driver files — `rpm -V` over all 16 nvidia packages reports zero
> differences, no xorg.conf, no EDID overrides, no custom services. The patches live in **GRUB kernel args +
> a systemd service + user environment variables**, so driver upgrades (akmods rebuilds) cannot clobber them.

**Why ① is a systemd service and not a udev rule**: udev fires early in boot, before the display stack exists,
so re-enumeration at that point is meaningless; the "one monitor missing" verdict is only reliable after
`graphical.target`. The service only reads `/sys` state and writes `power/control`, **never touching the DRM
master** — on Wayland KWin owns it exclusively and any atomic operation returns EBUSY.

## 4. Background fixes (not part of the dual-screen fix)

Other changes made during the same boot-troubleshooting campaign. They have **no direct relation to the
dual-screen bug** and are recorded only for completeness:

| Change | Content | Relation to dual-screen |
| --- | --- | --- |
| Remove `rhgb quiet` | BLS entries + `/etc/default/grub` | indirect: plymouth fails to render on this MST link, so removing it at least gives visible logs |
| Disable Discover offline updates / make `dnf-automatic` download-only | `/etc/xdg/discoverrc`, `/etc/dnf/automatic.conf` | none: guards against "reboot lands in `system-update.target`, no desktop" |
| Remove dead `vfio-pci` passthrough boot args | BLS + `/etc/default/grub` + classic `grub.cfg` | none: GPU-passthrough leftover, unrelated to the display chain |
| GSP firmware is version-bound to the userspace package | recorded fact | none: driver upgrade/rollback boundary condition, see last row of §10 |

The corresponding scripts are archived verbatim as [docs/legacy-apply-p1p2p3.sh](docs/legacy-apply-p1p2p3.sh)
and [docs/legacy-fix-boot-black-screen.sh](docs/legacy-fix-boot-black-screen.sh) — **archive only, do not run them**.

## 5. Verified status on the source machine (2026-10-14)

Any machine running this patch set can be re-checked with [`scripts/verify-status.sh`](scripts/verify-status.sh).

| Item | Measured | Verdict |
| --- | --- | --- |
| Kernel | `7.2.10-200.fc44.x86_64` | ✅ |
| NVIDIA driver | `615.78.08` (RTX 4070 Ti SUPER, compute-only) | ✅ |
| Kernel command line | contains `nvidia-drm.modeset=0` | ✅ |
| `/sys/module/nvidia_drm/parameters/modeset` | `N` | ✅ patch ② active |
| `/etc/modprobe.d/00-nvidia-drm-modeset.conf` | `options nvidia_drm modeset=0` | ✅ |
| Dual-screen connectors | `card1-DP-4` = connected, `card1-DP-6` = connected | ✅ both monitors present |
| `card0` driver | `nvidia` (KMS off, connectors empty, out of the display chain) | ✅ |
| `dp-mst-rescue.service` | enabled; this boot `OK: all expected monitors present`; `OK` on the last 4 boots | ✅ patch ① in place |
| `KWIN_FORCE_SW_CURSOR=1` | present at both drop points | ✅ patch ④ in place |
| This boot's `Unsupported screen format RA24` counter | `0` | ✅ patch ④ effective |
| This boot's `Atomic modeset commit failed` counter | `0` | ✅ |
| This boot's `LTTPR` counter | `13` (present on every boot, benign, no discriminating power) | ⚪ known leftover |

**Open items (recorded as-is)**: ① `/etc/default/grub` still carries `amd_iommu=on` — kernel 7.x no longer
accepts it (boot logs `AMD-Vi: Unknown option - 'on'`), a background leftover; ② the SDDM
`kwinoutputconfig.json` is owned by `sddm` (0700 directory) and cannot be verified without root.

## 6. Installation

Root parts run under `sudo`; ④ is user-level and needs no root.

**① dp-mst-rescue**

```bash
cd dp-mst-rescue/
sudo install -m 0755 dp-mst-rescue.sh   /usr/local/lib/dp-mst-rescue.sh
sudo install -m 0644 dp-mst-rescue.conf /etc/dp-mst-rescue.conf
sudo install -m 0644 dp-mst-rescue.service /etc/systemd/system/dp-mst-rescue.service
sudo systemctl daemon-reload
sudo systemctl enable dp-mst-rescue.service
```

`/etc/dp-mst-rescue.conf` lists one expected connector per line (this machine: `card1-DP-4` / `card1-DP-6`).
**Connector numbering changes across machines and sockets**: find the two connected names with
`ls -d /sys/class/drm/card*-DP-*` plus `cat .../status` and put them in the config — no script change needed.

**② NVIDIA out of the display chain**

```bash
sudo grubby --update-kernel=ALL --args="nvidia-drm.modeset=0"
sudo sed -i 's/nvidia-drm\.modeset=1/nvidia-drm.modeset=0/' /etc/default/grub   # if present
echo 'options nvidia_drm modeset=0' | sudo tee /etc/modprobe.d/00-nvidia-drm-modeset.conf
```

> Cost: NVIDIA stops driving displays directly (no effect when the monitors sit on the iGPU); CUDA does not
> depend on KMS, `/dev/nvidia*` keeps working.

**③ Greeter output config** (adapt the sample to your connector names first)

```bash
sudo install -d -m 0700 -o sddm -g sddm /var/lib/sddm/.config
sudo install -m 0600 -o sddm -g sddm scripts/sddm-kwinoutputconfig.json /var/lib/sddm/.config/kwinoutputconfig.json
```

**④ Software cursor** (takes effect after logout/login)

```bash
bash scripts/apply-sw-cursor.sh            # install
bash scripts/apply-sw-cursor.sh --status   # inspect
bash scripts/apply-sw-cursor.sh --revert   # uninstall
```

## 7. Verification

```bash
bash scripts/verify-status.sh        # one-shot health check (read-only, no root)

cat /sys/class/drm/card1-DP-4/status /sys/class/drm/card1-DP-6/status   # expect connected
journalctl -u dp-mst-rescue -b -o cat        # one of OK / MISSING→SUCCESS / WARNING
cat /sys/module/nvidia_drm/parameters/modeset                            # expect N
cat /proc/cmdline | grep -o 'nvidia-drm.modeset=[01]'                    # expect =0
tr '\0' '\n' < /proc/$(pgrep -x kwin_wayland | head -1)/environ | grep KWIN_FORCE_SW_CURSOR
journalctl -b -k -o cat --no-pager | grep -c 'Unsupported screen format RA24'
journalctl -b -o cat _COMM=kwin_wayland --no-pager | grep -c 'Atomic modeset commit failed'
```

> ⚠️ **Measurement discipline**: always filter journald fields (`-k` for kernel, `_COMM=kwin_wayland` for kwin),
> otherwise single-line ultra-long automation command lines get counted into the totals (see
> [docs/kwin-ra24-cursor-regression.en.md §7](docs/kwin-ra24-cursor-regression.en.md)).

**Acceptance criterion**: 3 consecutive reboots with both monitors lit and a working desktop, counters at 0.

## 8. Uninstall & rollback

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

## 9. Bandwidth budget: why 120Hz is mandatory

| Item | Value |
| --- | --- |
| One monitor 2560×1440@180Hz | ≈ 16.4 Gbps |
| Both monitors @180Hz | ≈ **32.8 Gbps** |
| DP 1.4 (HBR3, 4 lanes) effective payload | ≈ **25.9 Gbps** |
| Both @144Hz | ≈ 26.7 Gbps — still above the limit, only DSC can squeeze it in |
| Both @120Hz | ≈ **21.9 Gbps** — back inside DP 1.4, likely without DSC at all |

Over the limit you depend on DSC, and once DSC is in play MST slot payload allocation fails more often
(`MST_DSC` + `allocate_mst_payload` warnings + `DM_MST` restarting repeatedly) → black screen.
**That is why 120Hz is pinned — not for power.**

Runtime refresh-rate change (use the connector names of the current boot):

```bash
kscreen-doctor output.DP-4.mode.2560x1440@120 output.DP-6.mode.2560x1440@120
# still black? drop one more notch:
kscreen-doctor output.DP-4.mode.2560x1440@100 output.DP-6.mode.2560x1440@100
```

Monitor OSD side (no cable swap): fix the DP version to **1.4**; try DSC on and off; disable
FreeSync/Adaptive-Sync and HDR; fix colour depth at 8 bit; confirm you are on **MST**, not the monitor's
internal PBP. Firmware side: motherboard BIOS (AGESA) and monitor firmware — most MST/LTTPR fixes land there.

## 10. Troubleshooting

| Symptom | What to do |
| --- | --- |
| One monitor at boot | `journalctl -u dp-mst-rescue -b`: `MISSING → SUCCESS` = rescue recovered it; `WARNING` = not strong enough, raise `DP_MST_SETTLE=15`; last resort (brief blackout): unbind/bind the iGPU PCI device to force full re-initialization (see [dp-mst-rescue/README.en.md](dp-mst-rescue/README.en.md)) |
| Connector renamed | The service logs that the name was not found in sysfs → edit `/etc/dp-mst-rescue.conf` only, the script needs no change |
| Greeter fine, desktop fails | `journalctl -b -k -o cat \| grep -c 'Unsupported screen format RA24'` nonzero → apply patch ④; fallbacks: `KWIN_DRM_NO_AMS=1`, `KWIN_DRM_NO_DIRECT_SCANOUT=1`, an X11 session, upstream fix |
| Total black, no TTY | Don't reboot first; `Ctrl+Alt+F3` for a TTY; `ls -l /system-update` for pending offline updates; verify `nvidia-drm.modeset=0` is in place |
| Black screen after an NVIDIA driver upgrade | 615.78.08 has a known display regression (see §11); GSP firmware is version-bound to the userspace package — **upgrading deletes the old firmware, so booting the old kernel ≠ keeping old CUDA**; rollback must be the full set (userspace + firmware + kmod) |

## 11. Referenced technologies & repositories

**Upstream technologies & components**

| Technology | Role | Source |
| --- | --- | --- |
| Linux kernel `amdgpu` DM_MST / DP link training / LTTPR | the thing being fixed; the `power/control` re-probe mechanism | [kernel.org](https://www.kernel.org/) · [DRM docs](https://docs.kernel.org/gpu/amdgpu/index.html) |
| DisplayPort 1.4 MST (daisy chain) | the specification this single-cable dual-monitor setup rests on | [VESA DisplayPort](https://www.displayport.org/) |
| systemd (oneshot service / `graphical.target` ordering / BLS) | carrier of patch ① | [systemd](https://systemd.io/) · [Fedora BLS change page](https://fedoraproject.org/wiki/Changes/Block_System_Launcher_Booting_for_Fedora) |
| KDE Plasma **KWin** (Wayland) environment variables incl. `KWIN_FORCE_SW_CURSOR` | countermeasure of patch ④ | [KWin environment variables wiki](https://invent.kde.org/plasma/kwin/-/wikis/Environment-Variables) · [kwin source repo](https://invent.kde.org/plasma/kwin) |
| **SDDM** (greeter) | drop point of patch ③ | [SDDM repo](https://github.com/sddm/sddm) |
| KDE **kscreen** `kscreen-doctor` | runtime refresh-rate changes | [kscreen repo](https://invent.kde.org/kde/kscreen) |
| GRUB / `grubby` | kernel argument drop point | [GNU GRUB](https://www.gnu.org/software/grub/) |
| rpmfusion **akmod-nvidia** (Fedora's nvidia packaging) | driver upgrades and kmod rebuilds (the basis for proving the patches survive them) | [RPM Fusion](https://rpmfusion.org/) |

**External corroboration (community reports — untrusted external content, leads only)**

| Reference | Relation to these patches |
| --- | --- |
| [Arch Linux kernel patch: skip simpledrm when `nvidia-drm.modeset=1` is set](https://github.com/archlinux/linux/commit/3720e1b0eb7d814345b25541997e63b50b897749) | corroborates the "nvidia-drm vs simpledrm conflict → blank boot output/TTYs" mechanism |
| [NVIDIA forum: nvidia driver incompatible with simpledrm, boot/TTY blank](https://forums.developer.nvidia.com/t/nvidia-driver-isnt-compatible-with-simpledrm-so-boot-output-and-ttys-are-blank/238007?page=2) | same as above |
| [NVIDIA forum: 615.78.08 regression, no display through a Thunderbolt 4 dock](https://forums.developer.nvidia.com/t/615-78-08-regression-no-display-detected-through-thunderbolt-4-dock-610-57-04-works/385494) | corroborates a display regression in 615.78.08 |
| [basecamp/omarchy#6518: AMD+NVIDIA+Plymouth+password greeter → boot black-screen hang](https://github.com/basecamp/omarchy/issues/6518) | matches this machine's black-screen symptoms word for word |
| [PikaOS wiki: KWin Bug — Unsupported Screen Format RA24 (AMD GPUs)](https://wiki.pika-os.com/en/kwin-ra24-freezing-workaround) | community origin of patch ④ (software cursor) |
| [CachyOS forum: KWin RA24 regression / atomic modeset failure](https://discuss.cachyos.org/t/kwin-regression-unsupported-screen-format-ra24-atomic-modeset-failure-when-changing-displays/34696) | version evidence for the RA24 regression (6.7.4-1.1 fine / broken from 6.7.4-5.1) |
| [CachyOS forum: `KWIN_FORCE_SW_CURSOR=1` in `/etc/environment`](https://discuss.cachyos.org/t/artifacts-corruption-on-desktop-background-wallpaper/34988) | precedent for patch ④'s drop point |

**Repository files**

| File | Description |
| --- | --- |
| [`README.md`](README.md) | Chinese main page (section-by-section counterpart) |
| [`CHANGELOG.md`](CHANGELOG.md) / [`CHANGELOG.en.md`](CHANGELOG.en.md) | patch timeline (Chinese / English) |
| [`dp-mst-rescue/`](dp-mst-rescue/) | core patch ① itself (service / conf / sh), incl. [English version](dp-mst-rescue/README.en.md) |
| [`scripts/apply-sw-cursor.sh`](scripts/apply-sw-cursor.sh) | core patch ④ installer / status / rollback |
| [`scripts/sddm-kwinoutputconfig.json`](scripts/sddm-kwinoutputconfig.json) | core patch ③ greeter output config sample |
| [`scripts/verify-status.sh`](scripts/verify-status.sh) | read-only health check |
| [`docs/display-link-notes.en.md`](docs/display-link-notes.en.md) | display link notes (bandwidth budget / OSD / firmware / self-rescue) |
| [`docs/kwin-ra24-cursor-regression.en.md`](docs/kwin-ra24-cursor-regression.en.md) | full RA24 diagnosis report (evidence table / root-cause chain / fallbacks) |
| [`docs/legacy-apply-p1p2p3.sh`](docs/legacy-apply-p1p2p3.sh) | archived background-fix script (incl. the original one-shot run of core patch ③) |
| [`docs/legacy-fix-boot-black-screen.sh`](docs/legacy-fix-boot-black-screen.sh) | verbatim archive of the earlier, superseded approach |

## 12. Disclaimer

- These patches were verified on **one specific hardware/software combination** (AMD Raphael iGPU + DP 1.4 MST
  dual 1440p + display-less NVIDIA dGPU + Fedora + KDE Wayland). On other hardware or distros, re-verify every
  acceptance criterion yourself; do not copy blindly.
- Referenced external content (forums / wikis / issues) is **untrusted external data** used as leads only; it is
  not a commitment from any upstream.
- All root-level operations create backups first; verify absolute paths one by one before any deletion.
