# dp-mst-rescue — Boot-time rescue for AMD DP MST dual monitors

[简体中文](README.md) · **English**

> Core patch ①. Installation needs root. Repository entry point: [`../README.en.md`](../README.en.md).

## Context

- Two 2560×1440 monitors ride **DP MST** on the **AMD Raphael iGPU `card1`**, as `card1-DP-4` / `card1-DP-6`.
- `card0` is the NVIDIA dGPU, with no monitor attached.
- Symptom: extended-desktop mode was fine; the split layout occasionally lit only one monitor, and **at boot
  it was 100% one-monitor**.
- First safety net: KWin's `~/.config/kwinoutputconfig.json` (applies the correct layout once outputs are detected).
- This service is the second net, at the **kernel/driver level**: if an MST monitor is not enumerated after
  boot, it forces AMDGPU to re-train the DP link / re-enumerate MST.

## Why a systemd service and not a pure udev rule

- udev rules fire **early in boot**, before the display stack (KWin, DP link training) exists, so
  re-enumeration at that point is meaningless.
- The "one monitor missing at boot" verdict is only reliable **after the display stack is up**, so running
  after `graphical.target` is the dependable placement.

## How it works

1. Starts as a oneshot after `graphical.target`.
2. Waits `DP_MST_SETTLE` (default 8 s) for the display stack to settle.
3. Reads the expected connectors from `/etc/dp-mst-rescue.conf` and checks each `/sys/class/drm/<conn>/status`.
4. All present → log and exit (the normal case; KWin handles the layout).
5. Any missing → write `power/control` on the missing connector: `on` → previous value (a runtime-PM cycle) to
   force the driver to re-probe DP/MST; re-check after 5 s.
6. Everything is logged to the journal with the `dp-mst-rescue:` prefix.

> It only reads `/sys` state and writes `power/control`, **never touching the DRM master** — on Wayland KWin
> owns it exclusively and any atomic operation returns EBUSY, so that path is deliberately avoided.

## Installation (root required)

```bash
cd dp-mst-rescue/

sudo install -m 0755 dp-mst-rescue.sh /usr/local/lib/dp-mst-rescue.sh
sudo install -m 0644 dp-mst-rescue.conf /etc/dp-mst-rescue.conf
sudo install -m 0644 dp-mst-rescue.service /etc/systemd/system/dp-mst-rescue.service

sudo systemctl daemon-reload
sudo systemctl enable dp-mst-rescue.service
```

## Manual test (verify the logic immediately, no reboot)

With both monitors present, a normal run prints `OK: 期望屏全部在位` ("all expected monitors present"):

```bash
DP_MST_SETTLE=0 sudo /usr/local/lib/dp-mst-rescue.sh
```

To deliberately exercise the re-probe path (confirm it runs, and whether a monitor drops and comes back):
temporarily put a non-existent connector name in the config, or run the cycle by hand:

```bash
# current state
cat /sys/class/drm/card1-DP-4/status /sys/class/drm/card1-DP-6/status
# manual runtime-PM cycle on DP-6 (root)
echo on   > /sys/class/drm/card1-DP-6/power/control; sleep 1
echo auto > /sys/class/drm/card1-DP-6/power/control; sleep 2
cat /sys/class/drm/card1-DP-6/status
```

## Verifying after a reboot

```bash
journalctl -u dp-mst-rescue -b          # this boot's log
ls /sys/class/drm/card1-DP-4/status /sys/class/drm/card1-DP-6/status
```

- `OK: 期望屏全部在位` → normal, the rescue was not needed.
- `MISSING ... SUCCESS: 全部恢复` → the rescue fired and recovered a monitor.
- `WARNING: 重探测后仍缺失` → the PM cycle was not strong enough, see the next section.

## If the runtime-PM cycle is not enough (still one monitor)

From gentle to aggressive:

1. Raise the settle time: `DP_MST_SETTLE=15` (add the environment variable before `ExecStart` in the
   `.service`, or change the script default).
2. Inspect kernel logs: `journalctl -k | grep -iE 'amdgpu|mst|dp|aux'`.
3. Last resort (causes a brief blackout, use with care): rebind the amdgpu PCI device to force full
   re-initialization of the card —
   ```bash
   sudo bash -c 'echo 0000:11:00.0 > /sys/bus/pci/drivers/amdgpu/unbind; sleep 2; echo 0000:11:00.0 > /sys/bus/pci/drivers/amdgpu/bind'
   ```
   All displays on that card vanish briefly and come back; only bake this into the script as a final fallback
   after confirming it works.

## If connector names change

Connector numbering can change between boots (the log reports the name was not found in sysfs). Edit
`/etc/dp-mst-rescue.conf` only; the script needs no change. Find the current names with
`ls -d /sys/class/drm/card1-DP-*` plus `cat .../status` and keep the two reporting `connected`.

## Uninstall

```bash
sudo systemctl disable --now dp-mst-rescue.service
sudo rm /etc/systemd/system/dp-mst-rescue.service /etc/dp-mst-rescue.conf /usr/local/lib/dp-mst-rescue.sh
sudo systemctl daemon-reload
```
