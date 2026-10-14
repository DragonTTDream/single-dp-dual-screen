#!/usr/bin/bash
# dp-mst-rescue.sh — 开机双保险：AMD DP MST 双屏缺失时强制重新探测。
# 原理：graphical.target 起来后，检查配置里期望的 DP 连接器是否 connected；
#       缺了就对该连接器做 runtime PM 循环 (power/control: on -> 原值)，
#       逼 AMDGPU 重新训练 DP 链路 / 重新枚举 MST 拓扑。
# 只读 /sys 状态、只写 power/control，不动 DRM master（Wayland 下安全）。
set -u

CONF="${DP_MST_CONF:-/etc/dp-mst-rescue.conf}"
PREFIX="dp-mst-rescue"
SETTLE="${DP_MST_SETTLE:-8}"   # 开机后等显示栈稳定的秒数；手动测试可设 0

log() { echo "$PREFIX: $*"; }

status_of() { cat "/sys/class/drm/$1/status" 2>/dev/null || echo "unknown"; }

# 对单个连接器强制 DP/MST 重探测：循环其 runtime PM control。
reprobe() {
    local conn="$1"
    local pctl="/sys/class/drm/$conn/power/control"
    if [ ! -e "$pctl" ]; then
        log "$conn: $pctl 不存在（连接器改名了？）跳过"
        return 1
    fi
    local cur; cur="$(cat "$pctl" 2>/dev/null || echo auto)"
    log "$conn: runtime PM 循环 (原值 '$cur') 以强制 DP/MST 重探测"
    if ! echo on > "$pctl" 2>/dev/null; then
        log "$conn: 写 'on' 失败（需要 root？）"
        return 1
    fi
    sleep 1
    # 恢复原值；写不回去就退回 auto
    echo "$cur" > "$pctl" 2>/dev/null || echo auto > "$pctl" 2>/dev/null
    sleep 2
    return 0
}

main() {
    # 读配置：每行一个期望连接器，'#' 后为注释
    local expected=()
    if [ -r "$CONF" ]; then
        local line
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%%#*}"
            line="$(printf '%s' "$line" | xargs 2>/dev/null || true)"
            [ -n "$line" ] && expected+=("$line")
        done < "$CONF"
    else
        log "ERROR: 配置 $CONF 不存在或不可读，退出"
        exit 1
    fi
    if [ ${#expected[@]} -eq 0 ]; then
        log "ERROR: 配置 $CONF 里没有期望连接器，退出"
        exit 1
    fi

    # 等显示栈稳定再判断（手动测试可 DP_MST_SETTLE=0）
    [ "$SETTLE" != "0" ] && sleep "$SETTLE"

    local missing=() renamed=() c s
    for c in "${expected[@]}"; do
        if [ ! -e "/sys/class/drm/$c/status" ]; then
            log "$c: /sys/class/drm 下不存在（可能改名）"
            renamed+=("$c"); continue
        fi
        s="$(status_of "$c")"
        log "$c: status=$s"
        [ "$s" = "connected" ] || missing+=("$c")
    done

    if [ ${#missing[@]} -eq 0 ]; then
        log "OK: 期望屏全部在位 (${expected[*]})"
        [ ${#renamed[@]} -gt 0 ] && log "NOTE: sysfs 里找不到: ${renamed[*]} —— 请更新 $CONF"
        exit 0
    fi

    log "MISSING: ${missing[*]} -> 开始重探测"
    for c in "${missing[@]}"; do reprobe "$c"; done

    sleep 5
    local still=()
    for c in "${expected[@]}"; do
        [ -e "/sys/class/drm/$c/status" ] || continue
        s="$(status_of "$c")"
        log "recheck $c: status=$s"
        [ "$s" = "connected" ] || still+=("$c")
    done

    if [ ${#still[@]} -eq 0 ]; then
        log "SUCCESS: 全部恢复"
    else
        log "WARNING: 重探测后仍缺失: ${still[*]}"
        log "  排查: journalctl -k | grep -iE 'amdgpu|mst|dp'"
        log "  或若连接器改名，更新 $CONF"
    fi
}

main "$@"
