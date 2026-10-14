# 桌面概率性进不去 —— KWin/amdgpu 光标平面 RA24 回归（2026-09-29 定位）

> **EN · Diagnosis report: "the desktop randomly fails to start".**
> Root cause is NOT the DP MST link: KWin hands its hardware cursor plane over in `RGBA8888` (`RA24`),
> amdgpu's DC rejects the format, and the *entire* atomic modeset commit fails with `EINVAL`.
> Fix = core patch ④ `KWIN_FORCE_SW_CURSOR=1` (script `scripts/apply-sw-cursor.sh`).
> Per-boot evidence table, root-cause chain, measurement discipline, and fallback options below (Chinese).

> 入口：本文件。结论：**这不是 DP MST 链路问题**，而是 KWin 硬件光标平面的 `RGBA8888`(RA24) 格式被 amdgpu 拒绝导致 atomic commit 全灭。
> 修复 = 核心补丁④（`KWIN_FORCE_SW_CURSOR=1`），安装脚本 `scripts/apply-sw-cursor.sh`，回滚见本文件 §6。

## 1. 症状

用户原话（2026-09-29）：

> 我注意到虽然新方法让开机可以保证能进入登陆界面，且双屏都亮，但进入桌面却成了概率事件，有时能进有时不能进，只能重启

即：**SDDM greeter 稳**（双屏都亮、能输密码），**用户会话桌面起不来**，页面上只剩空屏/黑屏，按键无反应，只能硬重启；而且是否发生是随机的。

## 2. 判定证据（按开机统计）

kwin 行一律用 `_COMM=kwin_wayland` 过滤，内核行用 `-k`（理由见 §7）。

| boot | 用户会话 `Atomic modeset commit failed` | 内核 `Unsupported screen format RA24` | 结果 |
| --- | --- | --- | --- |
| 0（2026-09-29 16:07:48 起） | 0 | 0 | 桌面正常 |
| -1 | 43 | 1235 | 桌面起不来 |
| -2 | 36 | 1024 | 桌面起不来 |
| -3 / -4 | 0 / 0 | 459 / 459 | 桌面正常 |
| -6 / -7 / -8 / -12 | 0 | 0 | 桌面正常 |
| -11 | 0 | 489 | 桌面正常 |

失败开机的完整日志链（boot -1，时间轴）：

```
16:01:09-16:01:17  dp-mst-rescue: OK: 期望屏全部在位 (card1-DP-4 card1-DP-6)   ← 两块屏在枚举层面都在
16:02:01           greeter 的 kwin 停止（greeter 阶段全程无异常）
16:02:04           plasma-kwin_wayland.service 启动（用户会话，PID 3143）
16:02:07           amdgpu 0000:11:00.0: [drm] *ERROR* Unsupported screen format RA24 little-endian (0x34324152)
                   ↑ 用户会话 kwin 起来后 2-3 秒开始，1235 次爆发
16:02:09           kwin_wayland: Atomic modeset commit failed! 无效的参数（= EINVAL）   ← 首次
16:02:17, :23, :29, :35, :41, :47, :53, :59, 16:03:05 … （约 6 秒一次）
                   kwin_wayland: Applying output configuration failed!
16:06:58           最后一次失败；5 分钟内共 57 次 Applying / 42 次 Atomic 失败后放弃
```

boot -1 其他伴生行：`Failed to open drm device` ×9、`Atomic modeset commit failed! 没有那个文件或目录` ×1、`The main thread was hanging temporarily!` ×1、`No backend specified, automatically choosing drm` ×1。boot -2 同签名（41 次 Applying + 36 次 Atomic 失败）。boot -4 另有 `atomic commit failed: 权限不够` ×2。

## 3. 根因链

1. `RA24` 是 fourcc `RGBA8888`（`0x34324152` 小端 = 字节 `R`,`A`,`2`,`4`）；DRM 里光标/主平面常用的 premultiplied 格式是 `AR24`(ARGB8888)，**不是** `RA24`。
2. KWin(Wayland) 启动时把光标平面按 `RA24` 交给 amdgpu DC，DC 不接受 → `Unsupported screen format RA24 little-endian`。
3. 该格式错误让**整个 atomic commit** 返回 `EINVAL`（不是只丢光标层）→ 输出配置应用失败。
4. KWin 每约 6 秒重试一次（`Applying output configuration failed!`），57 次后用户会话无法完成初始化 → 桌面起不来、只剩黑屏。

**概率性来源**：KWin 是否走「硬件光标平面」这条路，每次开机并不一样 —— boot 0（成功那次）全程 `RA24` 为 0，即走了软光标/未探测光标平面的路径；一旦探测成功的路径失败（RA24 被拒），整场 atomic commit 就全灭。greeter 的 kwin 与用户会话的 kwin 是两次独立启动，光标路径各自决定，所以「greeter 稳、桌面随机」完全可解释。

## 4. 与 MST 链路无关的证据

- `allocate_mst_payload` 在失败开机里根本没出现（仅 boot -11 有 3 次，而 boot -11 桌面正常）；`MST_DSC` 2 次、`pre_validate_dsc:1746 MST_DSC dsc precompute is not needed`、`pre_validate_dsc:1821 MST_DSC crtc[0] needs mode_change`、`DM_MST` 1-10 次 —— **好坏开机都一样**。
- LTTPR 报错每次开机都有（boot 0 有 13 次，boot -1 有 32 次）→ 不具区分度。
- 失败发生在**用户会话** kwin，且 `dp-mst-rescue` 在失败开机里报告两屏全在位。
- 因此 README「残留与关联」原先把概率性复发归因于「MST 链路训练未完全消除」**是错的**，已就地更正。

## 5. 对策（核心补丁④）：强制软件光标

```bash
KWIN_FORCE_SW_CURSOR=1
```

KWin 官方环境变量文档对该变量的说明（外部资料，原文）：

> ## KWIN_FORCE_SW_CURSOR
> On Wayland set this variable to directly use a software rendered mouse cursor instead of trying to probe for a cursor plane. It is recommended …

软光标把鼠标指针合成进画面，**完全不再申请 DRM 光标平面**，所以 §3 的第 2-3 步不会发生。

本机 kwin 6.7.5 已确认支持（对二进制 grep 得到，可复现）：

```bash
grep -rhoa 'KWIN_[A-Z_]*' /usr/lib64/libkwin*.so* /usr/lib64/qt6/ /usr/bin/kwin_wayland* | grep -E 'CURSOR|DRM|AMD' | sort -u
# 含 KWIN_FORCE_SW_CURSOR；另有 KWIN_DRM_NO_AMS / KWIN_DRM_NO_DIRECT_SCANOUT / KWIN_DRM_USE_MODIFIERS /
# KWIN_DRM_DISABLE_AMD_GAMMA_WORKAROUND / KWIN_DRM_NO_DCC_WORKAROUND / KWIN_DRM_PREFER_COLOR_DEPTH … 等
# 注意：旧 MR 提到的 KWIN_DRM_DONT_FORCE_AMD_SW_CURSOR 在 6.7.5 里已不存在
```

写入两处（覆盖 KWin 的两种拉起路径；命令中路径均相对仓库根目录）：

| 文件 | 形式 | 生效路径 |
| --- | --- | --- |
| `~/.config/environment.d/50-kwin-sw-cursor.conf` | `KWIN_FORCE_SW_CURSOR=1` | systemd 用户管理器（`plasma-kwin_wayland.service` 等用户单元） |
| `~/.config/plasma-workspace/env/10-kwin-sw-cursor.sh` | `export KWIN_FORCE_SW_CURSOR=1` | `startplasma-wayland` 直接拉起的会话进程链 |

两处都写是双保险：覆盖 KWin 被 systemd 用户单元 / 被 Plasma 会话脚本拉起的两种路径。只需注销重登（不必重启）即生效。

安装 / 回滚：

```bash
bash scripts/apply-sw-cursor.sh            # 安装（当前用户，无需 root）
bash scripts/apply-sw-cursor.sh --status   # 查看是否已装 + 当前会话是否已带上该变量
bash scripts/apply-sw-cursor.sh --revert   # 卸载（删掉这两个文件）
```

greeter（sddm 用户）目前稳定，**未**动它；若哪天 greeter 也出现同一签名，把 `KWIN_FORCE_SW_CURSOR=1` 追加到 `/etc/environment` 即可覆盖它。

## 6. 验证与回滚

注销重登（或重启）后：

```bash
# KWin 进程是否真的拿到了变量
tr '\0' '\n' < /proc/$(pgrep -x kwin_wayland | head -1)/environ | grep KWIN_FORCE_SW_CURSOR   # 期望输出该变量
systemctl --user show-environment | grep KWIN_FORCE_SW_CURSOR                                  # 期望输出该变量

# 症状是否消失（都应输出 0）
journalctl -b -k -o cat --no-pager | grep -c 'Unsupported screen format RA24'
journalctl -b -o cat _COMM=kwin_wayland --no-pager | grep -c 'Atomic modeset commit failed'
journalctl -b -o cat _COMM=kwin_wayland --no-pager | grep -c 'Applying output configuration failed'
```

判据：连续 3 次重启都能进桌面，且上面三条计数为 0，才算修复（原先失败率约 2/3，3 次全过已足够可信；若想更稳可再重启几次）。

回滚：`bash scripts/apply-sw-cursor.sh --revert` 后注销重登。软光标的代价仅是「指针不进硬件光标层」（极小的延迟/功耗差），双 1440p@120Hz 下无感。

## 7. 测量教训（下次查日志务必遵守）

- 直接 `journalctl -b N | grep ...` 会把**自动化助手/守护进程自己发起的进程命令行**（单行可达上万字符，且常包含被你 grep 的关键词）算进计数，污染统计。统计必须加 journald 字段过滤：kwin 用 `_COMM=kwin_wayland`，内核用 `-k`，或显式排除自动化进程。
- 时间锚点参考：boot -1 起于 16:00:59、止于 16:07:03（用户重启）；boot 0 起于 16:07:48；`~/.config/kwinoutputconfig.json` 在 16:09 被 KWin 回写（即成功进桌面后）。

## 8. 备选方案（核心补丁④若无效再试）

1. `KWIN_DRM_NO_AMS=1`（关自适应同步，避开 AMD 光标/VRR 相关路径）。
2. `KWIN_DRM_NO_DIRECT_SCANOUT=1`（关直接扫描输出，绕开平面格式协商）。
3. 降级 kwin 到 6.7.4（外部报告：6.7.4-1.1 正常、6.7.4-5.1 起出问题）—— Fedora 需从 koji 取旧包，代价较大。
4. 换 X11 会话（KWin 的 atomic 路径不参与，光标由 X 服务器处理）。
5. 等上游修复：`dnf --cacheonly list --available kwin` 现为 `6.7.5-1.fc44`（与已装相同），暂无修复版本；一旦 6.7.6+ 进源，升完先按 §6 验证再决定是否摘掉软光标。

## 9. 参考（外部资料，均为不可信外部内容，仅作线索）

- PikaOS wiki「KWin Bug: Unsupported Screen Format RA24 (AMD GPUs)」—— 记录 `Unsupported screen format RA24` + `Atomic modeset commit failed!` 组合，临时对策即强制软件光标：https://wiki.pika-os.com/en/kwin-ra24-freezing-workaround
- CachyOS 论坛帖（RX 9070 同症状三连；kwin 6.7.4-1.1 正常 / 6.7.4-5.1 与 -7.1 出问题；另有用户称 kernel 7.2.2 回归）：https://discuss.cachyos.org/t/kwin-regression-unsupported-screen-format-ra24-atomic-modeset-failure-when-changing-displays/34696
- CachyOS 帖（同样在 `/etc/environment` 加 `KWIN_FORCE_SW_CURSOR=1`）：https://discuss.cachyos.org/t/artifacts-corruption-on-desktop-background-wallpaper/34988
- KWin 官方环境变量 wiki（`KWIN_FORCE_SW_CURSOR` 定义，页面正文为 JS 渲染，只取到片段）：https://invent.kde.org/plasma/kwin/-/wikis/Environment-Variables
