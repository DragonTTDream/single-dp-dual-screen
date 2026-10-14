# Desktop Fails to Start at Random — KWin/amdgpu Cursor Plane RA24 Regression (diagnosed 2026-09-29)

[简体中文](kwin-ra24-cursor-regression.md) · **English**

> Entry point: [`../README.en.md`](../README.en.md). Verdict: **this is not a DP MST link problem** — the KWin
> hardware cursor plane is submitted as `RGBA8888` (RA24), amdgpu rejects the format, and the entire atomic
> commit dies.
> Fix = core patch ④ (`KWIN_FORCE_SW_CURSOR=1`), installer `scripts/apply-sw-cursor.sh`, rollback in §6.

## 1. Symptom

The user's own words (2026-09-29):

> The new method reliably gets me to the login screen with both monitors lit, but reaching the desktop has
> become a random event — sometimes it starts, sometimes it doesn't, and the only way out is a reboot.

In other words: the **SDDM greeter is stable** (both monitors lit, password accepted), the **user session
desktop fails to start** — the screen stays empty/black, keypresses do nothing, only a hard reboot works, and
whether it happens is random.

## 2. Evidence (counted per boot)

kwin lines are always filtered with `_COMM=kwin_wayland`, kernel lines with `-k` (reason in §7).

| boot | user session `Atomic modeset commit failed` | kernel `Unsupported screen format RA24` | outcome |
| --- | --- | --- | --- |
| 0 (started 2026-09-29 16:07:48) | 0 | 0 | desktop fine |
| -1 | 43 | 1235 | desktop failed |
| -2 | 36 | 1024 | desktop failed |
| -3 / -4 | 0 / 0 | 459 / 459 | desktop fine |
| -6 / -7 / -8 / -12 | 0 | 0 | desktop fine |
| -11 | 0 | 489 | desktop fine |

Full log chain of a failing boot (boot -1, timeline):

```
16:01:09-16:01:17  dp-mst-rescue: OK: all expected monitors present (card1-DP-4 card1-DP-6)   ← both monitors enumerated
16:02:01           greeter's kwin stops (no anomalies at all during the greeter phase)
16:02:04           plasma-kwin_wayland.service starts (user session, PID 3143)
16:02:07           amdgpu 0000:11:00.0: [drm] *ERROR* Unsupported screen format RA24 little-endian (0x34324152)
                   ↑ starts 2-3 s after the user-session kwin comes up, 1235 occurrences
16:02:09           kwin_wayland: Atomic modeset commit failed! Invalid argument (= EINVAL)   ← first
16:02:17, :23, :29, :35, :41, :47, :53, :59, 16:03:05 … (roughly every 6 s)
                   kwin_wayland: Applying output configuration failed!
16:06:58           last failure; 57 Applying / 42 Atomic failures within 5 minutes, then it gives up
```

Other companion lines on boot -1: `Failed to open drm device` ×9, `Atomic modeset commit failed! No such file
or directory` ×1, `The main thread was hanging temporarily!` ×1, `No backend specified, automatically choosing
drm` ×1. Boot -2 has the same signature (41 Applying + 36 Atomic failures). Boot -4 additionally shows
`atomic commit failed: Permission denied` ×2.

## 3. Root-cause chain

1. `RA24` is the fourcc `RGBA8888` (`0x34324152` little-endian = bytes `R`,`A`,`2`,`4`); the premultiplied
   format normally used for cursor/primary planes in DRM is `AR24` (ARGB8888), **not** `RA24`.
2. At startup KWin (Wayland) hands the cursor plane over to amdgpu DC as `RA24`; DC refuses it →
   `Unsupported screen format RA24 little-endian`.
3. That format error makes the **entire atomic commit** return `EINVAL` (not just the cursor layer) → the
   output configuration cannot be applied.
4. KWin retries about every 6 seconds (`Applying output configuration failed!`); after 57 attempts the user
   session never finishes initializing → no desktop, only a black screen.

**Where the randomness comes from**: whether KWin takes the "hardware cursor plane" path differs from boot to
boot — on boot 0 (the successful one) `RA24` is 0 throughout, i.e. it took the software-cursor /
no-cursor-plane-probe path. Once the probe path is taken and rejected, the whole atomic commit dies. The
greeter's kwin and the user session's kwin are two independent startups that each decide their cursor path
separately, which fully explains "greeter stable, desktop random".

## 4. Evidence that this is unrelated to the MST link

- `allocate_mst_payload` does not appear at all in the failing boots (only boot -11 has 3 occurrences, and
  boot -11's desktop was fine); `MST_DSC` ×2, `pre_validate_dsc:1746 MST_DSC dsc precompute is not needed`,
  `pre_validate_dsc:1821 MST_DSC crtc[0] needs mode_change`, `DM_MST` ×1-10 — **identical on good and bad boots**.
- LTTPR errors occur on every boot (13 on boot 0, 32 on boot -1) → no discriminating power.
- The failure happens in the **user session** kwin, and `dp-mst-rescue` reports both monitors present on the
  failing boots.
- Therefore the README's earlier attribution of the probabilistic recurrence to "MST link training not fully
  eliminated" **was wrong**, and was corrected in place.

## 5. Countermeasure (core patch ④): force the software cursor

```bash
KWIN_FORCE_SW_CURSOR=1
```

KWin's official environment-variable documentation for this variable (external source, verbatim):

> ## KWIN_FORCE_SW_CURSOR
> On Wayland set this variable to directly use a software rendered mouse cursor instead of trying to probe for a cursor plane. It is recommended …

A software cursor composites the pointer into the picture and **never requests a DRM cursor plane at all**, so
steps 2-3 of §3 cannot happen.

Confirmed present in this machine's kwin 6.7.5 (found by grepping the binaries, reproducible):

```bash
grep -rhoa 'KWIN_[A-Z_]*' /usr/lib64/libkwin*.so* /usr/lib64/qt6/ /usr/bin/kwin_wayland* | grep -E 'CURSOR|DRM|AMD' | sort -u
# includes KWIN_FORCE_SW_CURSOR; also KWIN_DRM_NO_AMS / KWIN_DRM_NO_DIRECT_SCANOUT / KWIN_DRM_USE_MODIFIERS /
# KWIN_DRM_DISABLE_AMD_GAMMA_WORKAROUND / KWIN_DRM_NO_DCC_WORKAROUND / KWIN_DRM_PREFER_COLOR_DEPTH …
# note: KWIN_DRM_DONT_FORCE_AMD_SW_CURSOR, mentioned in an old MR, no longer exists in 6.7.5
```

Written at two drop points (covering both ways KWin is started; all paths relative to the repository root):

| File | Form | Activation path |
| --- | --- | --- |
| `~/.config/environment.d/50-kwin-sw-cursor.conf` | `KWIN_FORCE_SW_CURSOR=1` | systemd user manager (`plasma-kwin_wayland.service` and other user units) |
| `~/.config/plasma-workspace/env/10-kwin-sw-cursor.sh` | `export KWIN_FORCE_SW_CURSOR=1` | the process chain started directly by `startplasma-wayland` |

Writing both is a double net: it covers KWin started by a systemd user unit and KWin started by the Plasma
session script. Logout/login is enough; no reboot needed.

Install / rollback:

```bash
bash scripts/apply-sw-cursor.sh            # install (current user, no root)
bash scripts/apply-sw-cursor.sh --status   # installed? and is the variable live in this session?
bash scripts/apply-sw-cursor.sh --revert   # uninstall (removes those two files)
```

The greeter (the `sddm` user) is currently stable and was **not** touched; if it ever shows the same
signature, append `KWIN_FORCE_SW_CURSOR=1` to `/etc/environment` to cover it.

## 6. Verification and rollback

After logout/login (or a reboot):

```bash
# did KWin actually receive the variable
tr '\0' '\n' < /proc/$(pgrep -x kwin_wayland | head -1)/environ | grep KWIN_FORCE_SW_CURSOR   # expect the variable
systemctl --user show-environment | grep KWIN_FORCE_SW_CURSOR                                  # expect the variable

# did the symptom disappear (all should print 0)
journalctl -b -k -o cat --no-pager | grep -c 'Unsupported screen format RA24'
journalctl -b -o cat _COMM=kwin_wayland --no-pager | grep -c 'Atomic modeset commit failed'
journalctl -b -o cat _COMM=kwin_wayland --no-pager | grep -c 'Applying output configuration failed'
```

Acceptance criterion: 3 consecutive reboots reaching the desktop with all three counters at 0. (The original
failure rate was about 2/3, so 3 clean passes is already convincing; reboot a few more times if you want more
confidence.)

Rollback: `bash scripts/apply-sw-cursor.sh --revert`, then logout/login. The cost of a software cursor is only
"the pointer no longer lives in the hardware cursor plane" (a negligible latency/power difference), imperceptible
on dual 1440p@120Hz.

## 7. Measurement lesson (follow this whenever reading logs)

- Plain `journalctl -b N | grep ...` counts **command lines of processes started by automation daemons / helpers
  themselves** (a single line can reach tens of thousands of characters and often contains the very keyword you
  are grepping for), polluting the statistics. Always add journald field filters: `_COMM=kwin_wayland` for kwin,
  `-k` for the kernel, or explicitly exclude automation processes.
- Time anchors: boot -1 ran 16:00:59 → 16:07:03 (user reboot); boot 0 started 16:07:48;
  `~/.config/kwinoutputconfig.json` was rewritten by KWin at 16:09 (i.e. after a successful desktop start).

## 8. Fallback options (if core patch ④ turns out insufficient)

1. `KWIN_DRM_NO_AMS=1` (disable adaptive sync, avoiding AMD cursor/VRR paths).
2. `KWIN_DRM_NO_DIRECT_SCANOUT=1` (disable direct scanout, bypassing plane format negotiation).
3. Downgrade kwin to 6.7.4 (external reports: 6.7.4-1.1 fine, broken from 6.7.4-5.1) — on Fedora this needs an
   old package from koji, a heavy option.
4. Switch to an X11 session (KWin's atomic path is not involved; the X server handles the cursor).
5. Wait for the upstream fix: `dnf --cacheonly list --available kwin` currently shows `6.7.5-1.fc44` (same as
   installed), no fixed build yet; once 6.7.6+ lands, verify per §6 first, then decide whether to drop the
   software cursor.

## 9. References (external material — untrusted content, leads only)

- PikaOS wiki "KWin Bug: Unsupported Screen Format RA24 (AMD GPUs)" — documents the
  `Unsupported screen format RA24` + `Atomic modeset commit failed!` combination; the workaround is forcing the
  software cursor: https://wiki.pika-os.com/en/kwin-ra24-freezing-workaround
- CachyOS forum thread (same symptom on an RX 9070, three reports; kwin 6.7.4-1.1 fine / 6.7.4-5.1 and -7.1
  broken; another user reports a kernel 7.2.2 regression):
  https://discuss.cachyos.org/t/kwin-regression-unsupported-screen-format-ra24-atomic-modeset-failure-when-changing-displays/34696
- CachyOS thread (adds `KWIN_FORCE_SW_CURSOR=1` in `/etc/environment` as well):
  https://discuss.cachyos.org/t/artifacts-corruption-on-desktop-background-wallpaper/34988
- KWin official environment-variables wiki (definition of `KWIN_FORCE_SW_CURSOR`; the page body is JS-rendered,
  only a fragment was retrievable): https://invent.kde.org/plasma/kwin/-/wikis/Environment-Variables
