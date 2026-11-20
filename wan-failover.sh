#!/bin/bash
# 校园网 <-> 4G 棒 自动切换
#
# 设计原则（针对前几天晚上的事故逐条加固）：
#   1. 绝不让「半切换」状态存在：切走/切回都要验证，失败要回到可用状态
#   2. 任何失败都不能把 mihomo 留在绑定失效接口的状态（这是全断的根源）
#   3. 探测不依赖单一硬编码 IP（会失效），能用 mihomo DNS 动态拿真实 IP
#   4. 所有外部阻塞调用都有超时 + 关闭锁 fd，绝不卡死 timer
set -u

PRIMARY_IF="enp1s0"
PRIMARY_GW="192.168.1.1"
BACKUP_GW="192.168.68.1"
# 认证页地址：改成你学校的 Portal 入口
AUTH="${AUTH_HOST:-https://auth1.example.edu.cn/}"
TAG="wan-failover"
# 4G 棒网卡的 MAC，用来自动定位接口名（换成你自己的）
BACKUP_MAC="${BACKUP_MAC:-02:00:00:00:00:00}"
YSUNET_NET="172.21.0.0/16"
YSUNET_TABLE=200
MIHOMO_API="http://127.0.0.1:19090"
STICK_PASS="${STICK_PASS:?请先设置 STICK_PASS 环境变量}"
FALLBACK_BAIDU_IPS="110.242.70.57 110.242.69.21"
NET_URLS="https://www.baidu.com/ https://www.tencent.com/"
API_URLS="https://ps.air-outer.com/ https://api.xingchiapi.com/"
PROBE_STATE="/run/wan-failover.lastprobe"
FAIL_STATE="/run/wan-failover.failsince"
STICK_STATE="/run/wan-failover.stickfail"
MIHOMO_STATE="/run/wan-failover.mihomo"
PROBE_INTERVAL=180
AUTH_WAIT=600
STICK_RETRY=300
MIHOMO_RETRY=1800
OFFLINE_START=2330
OFFLINE_END=530

exec 9>/run/wan-failover.lock
flock -n 9 || exit 0

log() { logger -t "$TAG" "$*"; }

# 所有会 fork 常驻进程的调用都要 9>&-，否则锁 fd 被继承、锁永不释放
mihomo_stop()  { timeout 25 /usr/local/bin/appcenter-cli stop mihomo  >/dev/null 2>&1 9>&-; }
mihomo_start() { timeout 30 /usr/local/bin/appcenter-cli start mihomo >/dev/null 2>&1 9>&-; }

set_mihomo_iface() {
    curl -s -m 8 -o /dev/null -X PATCH -H 'Content-Type: application/json' \
        -d "{\"interface-name\":\"$1\"}" "$MIHOMO_API/configs" 2>/dev/null 9>&-
}

flush_mihomo_cache() {
    curl -s -m 6 -o /dev/null -X POST "$MIHOMO_API/cache/fakeip/flush" 2>/dev/null 9>&-
    curl -s -m 6 -o /dev/null -X POST "$MIHOMO_API/cache/dns/flush" 2>/dev/null 9>&-
}

mihomo_ready() { curl -s -m 3 -o /dev/null "$MIHOMO_API/version" 2>/dev/null 9>&-; }
mihomo_alive() { pgrep -f '/vol1/@appcenter/mihomo/mihomo -d' >/dev/null 2>&1; }

restart_mihomo() {
    log "restarting mihomo to rebind outbound"
    [ -x /usr/local/bin/fix-mihomo-dns.sh ] && /usr/local/bin/fix-mihomo-dns.sh >/dev/null 2>&1

    mihomo_stop
    local i
    for i in $(seq 1 15); do
        mihomo_alive || break
        sleep 1
    done
    if mihomo_alive; then
        log "mihomo still alive after 15s, force kill"
        pkill -9 -f '/vol1/@appcenter/mihomo/mihomo -d' 2>/dev/null
        sleep 1
    fi

    mihomo_start
    for i in $(seq 1 30); do
        if mihomo_ready; then
            sleep 2
            flush_mihomo_cache
            log "mihomo back online after ${i}s"
            return 0
        fi
        sleep 1
    done

    log "mihomo NOT ready in 30s, retry start once"
    mihomo_start
    for i in $(seq 1 20); do
        if mihomo_ready; then
            sleep 2
            flush_mihomo_cache
            log "mihomo back online on retry after ${i}s"
            return 0
        fi
        sleep 1
    done

    log "FATAL: mihomo failed to start"
    return 1
}

ensure_auth_route() {
    ip route replace default via "$PRIMARY_GW" dev "$PRIMARY_IF" table "$YSUNET_TABLE" 2>/dev/null
    ip rule del from "$YSUNET_NET" lookup "$YSUNET_TABLE" priority 5 2>/dev/null
    ip rule add from "$YSUNET_NET" lookup "$YSUNET_TABLE" priority 5 2>/dev/null
}

in_offline_window() {
    local hm
    hm=$(date +%H%M)
    hm=$((10#$hm))
    [ "$hm" -ge "$OFFLINE_START" ] || [ "$hm" -lt "$OFFLINE_END" ]
}

BACKUP_IF=""
for d in /sys/class/net/*; do
    n=${d##*/}
    [ "$n" = "lo" ] && continue
    if [ "$(cat "$d/address" 2>/dev/null)" = "$BACKUP_MAC" ]; then
        BACKUP_IF=$n
        break
    fi
done
[ -n "$BACKUP_IF" ] || exit 0

BACKUP_SRC=$(ip -4 -o addr show dev "$BACKUP_IF" 2>/dev/null | awk 'NR==1{print $4}' | cut -d/ -f1)
PRIMARY_SRC=$(ip -4 -o addr show dev "$PRIMARY_IF" 2>/dev/null | awk 'NR==1{print $4}' | cut -d/ -f1)

backup_active() { ip route show default 2>/dev/null | grep -q "dev $BACKUP_IF"; }

# 走 DSH 真实依赖的 API（走代理），失败再兜底测国内大厂
api_ok() {
    local url code
    for url in $API_URLS; do
        code=$(curl -s -m 15 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null 9>&-)
        case "${code:0:1}" in 2|3) return 0 ;; esac
        [ "$code" = "401" ] || [ "$code" = "403" ] && return 0
    done
    for url in $NET_URLS; do
        code=$(curl -s -m 12 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null 9>&-)
        case "${code:0:1}" in 2|3) return 0 ;; esac
    done
    return 1
}

# 切走验证用：超时更短，避免长时间占住 timer
api_ok_fast() {
    local url code
    for url in $API_URLS; do
        code=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null 9>&-)
        case "${code:0:1}" in 2|3) return 0 ;; esac
        [ "$code" = "401" ] || [ "$code" = "403" ] && return 0
    done
    return 1
}

auth_reachable() {
    local code
    code=$(curl -s -m 8 --interface "$PRIMARY_IF" -o /dev/null -w '%{http_code}' "$AUTH" 2>/dev/null 9>&-)
    case "${code:0:1}" in 2|3) return 0 ;; esac
    [ "$code" = "401" ] || [ "$code" = "403" ] && return 0
    return 1
}

# 通过 mihomo 的 DNS API 拿真实 IP（优于硬编码，IP 变了也能自适应）
resolve_via_mihomo() {
    local host=$1 out ips=""
    out=$(curl -s -m 6 "$MIHOMO_API/dns/query?name=$host&type=A" 2>/dev/null 9>&-)
    ips=$(printf '%s' "$out" | grep -oE '"data":"([0-9]{1,3}\.){3}[0-9]{1,3}"' \
          | cut -d'"' -f4 | grep -vE '^198\.18\.' | head -4)
    printf '%s' "$ips"
}

# 校园网"真能出网"判定：临时 /32 路由 + 真实 IP + 内容校验
# 内容长度 >800 才认，防 Portal 劫持页（约 499 字节）
primary_ok() {
    local host ip ips body
    [ -n "$PRIMARY_SRC" ] || return 1
    for host in www.baidu.com www.tencent.com; do
        ips=$(resolve_via_mihomo "$host")
        if [ -z "$ips" ] && [ "$host" = "www.baidu.com" ]; then
            ips=$FALLBACK_BAIDU_IPS
        fi
        for ip in $(printf '%s' "$ips" | head -2); do
            ip route replace "$ip/32" via "$PRIMARY_GW" dev "$PRIMARY_IF" src "$PRIMARY_SRC" 2>/dev/null
            body=$(curl -s -m 6 --resolve "$host:80:$ip" "http://$host/" 2>/dev/null 9>&-)
            ip route del "$ip/32" via "$PRIMARY_GW" dev "$PRIMARY_IF" 2>/dev/null
            # 真实页面通常 >800 字节；Portal 劫持页约 499 字节且含 auth1/eportal 特征
            if [ "${#body}" -gt 800 ]; then
                if ! printf '%s' "$body" | grep -qiE 'auth1\.ysu\.edu\.cn|eportal|top\.self\.location'; then
                    return 0
                fi
            fi
        done
    done
    return 1
}
stick_online() {
    local code
    code=$(timeout 16 sshpass -p "$STICK_PASS" ssh -o StrictHostKeyChecking=no \
        -o ConnectTimeout=5 -o LogLevel=ERROR "root@$BACKUP_GW" \
        "curl -s -m 6 -o /dev/null -w '%{http_code}' https://www.baidu.com/" 2>/dev/null 9>&-)
    case "${code:0:1}" in 2|3) return 0 ;; esac
    return 1
}

stick_reconnect() {
    timeout 220 sshpass -p "$STICK_PASS" ssh -o StrictHostKeyChecking=no \
        -o ConnectTimeout=8 -o LogLevel=ERROR "root@$BACKUP_GW" \
        "bash /usr/local/bin/reconnect-wifi.sh" 2>/dev/null 9>&- | tr -d '\r'
}

# 切回校园网：必须重启 mihomo，且失败要回切 4G，绝不留在"两边都不通"的状态
switch_back() {
    ip route del default via "$BACKUP_GW" dev "$BACKUP_IF" 2>/dev/null
    set_mihomo_iface ""
    restart_mihomo
    rm -f "$PROBE_STATE" "$FAIL_STATE" "$STICK_STATE" 2>/dev/null

    sleep 3
    if api_ok; then
        log "switch back verified OK -> now on $PRIMARY_IF"
        return 0
    fi

    log "switch back verified FAILED -> returning to backup $BACKUP_IF"
    ip route add default via "$BACKUP_GW" dev "$BACKUP_IF" src "$BACKUP_SRC" metric 50 2>/dev/null
    set_mihomo_iface "$BACKUP_IF"
    restart_mihomo
    # 推迟 600s 再探测校园网，避免与失败回切形成抖动循环
    echo "$(( $(date +%s) + 420 ))" > "$PROBE_STATE" 2>/dev/null
    return 1
}

ensure_auth_route
[ -n "$BACKUP_SRC" ] || exit 0

# 面板手动请求重启 mihomo
if [ -f /run/mihomo-restart.request ]; then
    rm -f /run/mihomo-restart.request 2>/dev/null
    log "mihomo restart requested by panel"
    restart_mihomo
fi

# ============ 已在 4G 上 ============
if backup_active; then
    if ! api_ok; then
        now=$(date +%s)
        stick_last=$(cat "$STICK_STATE" 2>/dev/null || echo 0)
        if [ $((now - stick_last)) -ge "$STICK_RETRY" ]; then
            echo "$now" > "$STICK_STATE" 2>/dev/null
            log "backup active but no internet -> wifi reconnect (up to 3 attempts)"
            REC=$(stick_reconnect)
            log "wifi reconnect: ${REC:-<no response>}"
            case "$REC" in
                OK:*)
                    log "wifi verified online -> restarting mihomo to rebuild outbound"
                    restart_mihomo
                    ;;
                ALREADY:*)
                    mh_last=$(cat "$MIHOMO_STATE" 2>/dev/null || echo 0)
                    if [ $((now - mh_last)) -ge "$MIHOMO_RETRY" ]; then
                        echo "$now" > "$MIHOMO_STATE" 2>/dev/null
                        flush_mihomo_cache
                        sleep 3
                        if ! api_ok; then
                            log "wifi up but still no internet -> restart mihomo (cooldown ${MIHOMO_RETRY}s)"
                            restart_mihomo
                        fi
                    fi
                    ;;
                *)
                    log "wifi reconnect not possible: ${REC:-<no response>}"
                    ;;
            esac
        fi
    fi

    # 顺便探测校园网是否恢复
    now=$(date +%s)
    last=$(cat "$PROBE_STATE" 2>/dev/null || echo 0)
    if [ $((now - last)) -ge "$PROBE_INTERVAL" ]; then
        echo "$now" > "$PROBE_STATE" 2>/dev/null
        if primary_ok; then
            log "primary recovered -> switching back"
            switch_back
        fi
    fi
    exit 0
fi

# ============ 主线路看起来正常 ============
if api_ok; then
    rm -f "$FAIL_STATE" "$STICK_STATE" 2>/dev/null
    exit 0
fi

# ============ 主线路不通 ============
if auth_reachable; then
    if in_offline_window; then
        log "offline window + no internet -> switching (auth page up but useless)"
    else
        now=$(date +%s)
        if [ -f "$FAIL_STATE" ]; then
            since=$(cat "$FAIL_STATE" 2>/dev/null || echo "$now")
        else
            echo "$now" > "$FAIL_STATE" 2>/dev/null
            since=$now
        fi
        if [ $((now - since)) -lt "$AUTH_WAIT" ]; then
            exit 0
        fi
        log "auth page reachable but offline $((now - since))s -> switching"
    fi
fi

now=$(date +%s)
stick_last=$(cat "$STICK_STATE" 2>/dev/null || echo 0)
if [ $((now - stick_last)) -lt "$STICK_RETRY" ]; then
    exit 0
fi

# 切换前先确认备线真能出网
if ! stick_online; then
    echo "$now" > "$STICK_STATE" 2>/dev/null
    log "primary DOWN and backup has NO internet -> wifi reconnect (up to 3 attempts)"
    REC=$(stick_reconnect)
    log "wifi reconnect: ${REC:-<no response>}"
    case "$REC" in
        OK:*) log "wifi recovered, continuing with switch" ;;
        *)    log "auto-reconnect not possible -> skip switching (cooldown ${STICK_RETRY}s)"; exit 0 ;;
    esac
fi

# ============ 执行切换 ============
rm -f "$STICK_STATE" 2>/dev/null
ip route add default via "$BACKUP_GW" dev "$BACKUP_IF" src "$BACKUP_SRC" metric 50 2>/dev/null
set_mihomo_iface "$BACKUP_IF"

if ! restart_mihomo; then
    log "switch aborted: mihomo could not start, keeping primary route intact"
    ip route del default via "$BACKUP_GW" dev "$BACKUP_IF" 2>/dev/null
    set_mihomo_iface ""
    echo "$now" > "$STICK_STATE" 2>/dev/null
    exit 0
fi

SWITCHED=0
for i in 1 2 3; do
    sleep 6
    if api_ok_fast; then
        SWITCHED=1
        break
    fi
    log "switch verify $i/3 failed"
done

if [ "$SWITCHED" = "1" ]; then
    rm -f "$FAIL_STATE" 2>/dev/null
    log "switched to $BACKUP_IF ($BACKUP_SRC), verified OK"
else
    # 再给 mihomo 一次机会（出站可能没重建好）
    log "switch verify failed 3 times -> restart mihomo once more"
    restart_mihomo
    sleep 5
    if api_ok_fast; then
        log "switched after mihomo retry, verified OK"
        rm -f "$FAIL_STATE" 2>/dev/null
    else
        # 关键：**保留 4G 路由不清**，避免 mihomo 绑在失效接口上导致彻底断网；
        # 同时 primary_ok 探测仍在跑，校园网一恢复就会切回
        echo "$now" > "$STICK_STATE" 2>/dev/null
        log "switch FAIL still no internet -> KEEP 4G route (avoid half-state), cooldown ${STICK_RETRY}s, primary probe active"
    fi
fi
