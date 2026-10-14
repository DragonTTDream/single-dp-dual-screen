# CHANGELOG — Single-Cable Dual-Monitor Patch Timeline

[简体中文](CHANGELOG.md) · **English**

> Every entry below is traceable to log evidence (journalctl / audit / `rpm -V` / line-by-line logs); raw
> archives live in `docs/` and README §11.
> Labels: **CORE** = part of the dual-screen fix · **BACKGROUND** = done in the same campaign, not part of the dual-screen fix.

## 2026-09-24 — Core ① dp-mst-rescue installed

- Symptom: boot lit only one of the two monitors, 100% reproducible (incomplete MST enumeration).
- Drop points: `/etc/systemd/system/dp-mst-rescue.service` (enabled) + `/etc/dp-mst-rescue.conf` + `/usr/local/lib/dp-mst-rescue.sh`.
- Mechanism: after `graphical.target`, check the expected connectors; for any missing one, cycle its runtime
  power management (`power/control: on → previous`) to force amdgpu to re-train the DP link / re-enumerate MST.
  The DRM master is never touched.

## 2026-09-27 — Boot black-screen fix (Core ③ + background)

- Root cause: unstable DP link training (LTTPR misread on every boot) + an amdgpu MST payload allocation race
  at the first modeset → KWin atomic commit `EINVAL`.
- **Core ③**: pinned the SDDM greeter output config (DP-4 top / DP-6 bottom, 120Hz, scale 1.3).
- Background: removed `rhgb quiet` (grubby does not touch BLS — edit `/boot/loader/entries/*.conf` directly);
  disabled Discover offline updates; made `dnf-automatic` download-only; dropped the dead `vfio-pci.ids` /
  `rd.driver.pre=vfio-pci` args.
- Same window: kernel updated to 7.2.7-200 and set as default; `dracut --force` removed the baked-in
  `rd.driver.pre=vfio_pci`.
- Result: boot black screen confirmed fixed.

## 2026-09-29 — Core ④ software cursor (RA24 regression)

- Newly exposed: greeter stable, desktop startup random (~2/3 failure rate).
- Evidence: failing boots logged 1024–1235 × `Unsupported screen format RA24` and 36–43 ×
  `Atomic modeset commit failed`; successful boots logged 0. MST/DSC/LTTPR fingerprints were identical on good
  and bad boots → **not an MST link problem** (the earlier "MST training not fully eliminated" attribution was
  retracted on the spot).
- Root cause: KWin hands the cursor plane over as `RA24` (RGBA8888), amdgpu DC rejects it, and the *entire*
  atomic commit returns `EINVAL`.
- Countermeasure: `KWIN_FORCE_SW_CURSOR=1` at two drop points (environment.d + plasma env). Acceptance: 3
  consecutive reboots reaching the desktop with all three counters at 0.

## 2026-10-14 — Driver-upgrade black screen and Core ②

- Background: NVIDIA driver 615.71.09 → 615.78.08 upgraded successfully (an rpmfusion metadata freeze fixed
  along the way).
- Incident: 7.2.10 + 615.78.08 hung black on reboot **2 out of 2 times**; only booting the old kernel got in.
- Evidence refuted the "nvidia-drm steals card0" theory (DRM topology line-for-line identical) — the real
  variable was the driver version.
- Key boundary: **GSP firmware is version-bound to the userspace package**, so upgrading deletes the old
  firmware; "booting the old kernel" restores the login screen at the price of **no CUDA, permanently**. CUDA
  runs only on 7.2.10 + 615.78.08.
- Topology proof: both monitors sit on the iGPU (`card1-DP-4` / `card1-DP-6`, MST) while NVIDIA reports
  `Cannot find any crtc or sizes` — **no monitor is attached to NVIDIA at all**, so `nvidia-drm.modeset=1`
  buys nothing for displays yet is the black-screen entry point.
- "Just delete the cmdline argument" was **falsified as a no-op**: 615.78.08 defaults to modeset=1, and after
  deletion `modeset=Y`, card0 remained nvidia-owned, topology identical.
- **Core ② final form**: explicit `nvidia-drm.modeset=0` at two drop points (GRUB cmdline +
  `/etc/modprobe.d/00-nvidia-drm-modeset.conf`).
- Verified: `modeset=N`, card0 connectors empty, CUDA / dual monitors / rescue service all normal, 7.2.10
  boots cleanly.
- Side effect (background): vfio leftovers removed (`/etc/modprobe.d/vfio.conf`,
  `/etc/dracut.conf.d/vfio.conf` deleted + initramfs rebuilt, −247844 B) → the boot no longer claims the GPU.

## 2026-10-14 20:37 — Full re-verification (source of README §5's status table)

- Both connectors `connected`; `modeset=N`; dp-mst-rescue `OK` on the last 4 boots; both software-cursor drop
  points present; RA24 = 0, atomic failures = 0; `lsmod | grep vfio` empty.
- Open: a dead `amd_iommu=on` remains in `/etc/default/grub` (cleanup script prepared, not run); the
  sddm-owned greeter config cannot be verified as non-root.
