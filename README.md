# wan-failover

双出口自动切换脚本：主线路不通时切到 4G 备份链路，主线路恢复后自动切回。写给我自己那台跑着常驻服务的 NAS 用的。

## 场景

主线路是校园网，每晚 23:30 到次日 05:30 强制断网；白天也会无征兆掉线。备线是一根 4G 随身 WiFi，通过 USB 网卡挂在同一台机器上。断网时段与其干等，不如自动切过去。

```
                     ┌── enp1s0 ──> 主路由 192.168.1.1 ──> 校园网
本机 ────────────────┤
                     └── wlan0/usb ──> 4G 棒 192.168.68.1 ──> 4G
```

## 核心设计

脚本短，但有几条规则是被事故教出来的，改之前建议先读：

**1. 绝不留"半切换"状态。** 切换后连做 3 次验证（每次间隔 6 秒），全失败也**不回滚**主线路，而是保留 4G 路由并进入冷却。原因是：回滚会把代理内核（mihomo）的出站绑在一个已经死掉的接口上，结果是"主线路不通、4G 不通、代理也不通"——比不切换更糟。

**2. 切成不成功也要保住可用性。** 切换前先 SSH 到 4G 棒上实测能不能出网；棒子自己掉线就触发重连（最多 3 次），失败则跳过本次切换，等冷却。

**3. 探测不能只看 HTTP 状态码。** 强制门户会劫持 HTTP 并返回 200。所以主线路判定用"临时 /32 路由 + 真实 IP + 内容长度"，返回体小于 800 字节或含 `eportal` 特征词就判为被劫持。

**4. 换出口必须同步重绑代理出站。** 只改系统默认路由是不够的——mihomo 的出站网卡是独立配置的，要一起改，再重启并清 fakeip / DNS 缓存，否则域名仍然解析到旧映射。

**5. 所有阻塞调用都要超时，且关闭锁文件描述符。** 脚本用 `flock` 防重入，但任何 fork 出去的常驻进程都会继承锁 fd，导致锁永不释放。所以每个外部调用都带 `9>&-`。

## 部署

```bash
install -m 755 wan-failover.sh /usr/local/bin/wan-failover.sh

# 环境变量（systemd 里也可写 Environment=）
export STICK_PASS='你的4G棒密码'
```

systemd timer（每 3 分钟一次）：

```ini
# /etc/systemd/system/wan-failover.service
[Unit]
Description=WAN failover

[Service]
Type=oneshot
Environment=STICK_PASS=你的4G棒密码
ExecStart=/usr/local/bin/wan-failover.sh
```

```ini
# /etc/systemd/system/wan-failover.timer
[Unit]
Description=Run WAN failover every 3 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=3min

[Install]
WantedBy=timers.target
```

```bash
systemctl enable --now wan-failover.timer
```

脚本自身也做了 `flock` 重入保护，被 timer 频繁拉起不会叠加执行。

## 需要按环境改的变量

文件开头集中声明，主要是这几个：

| 变量 | 说明 |
|---|---|
| `PRIMARY_IF` / `PRIMARY_GW` | 主线路网卡与网关 |
| `BACKUP_GW` | 4G 棒的地址 |
| `BACKUP_MAC` | 4G 棒网卡的 MAC（脚本靠它自动找接口名，换设备要改） |
| `STICK_PASS` | 4G 棒的 SSH 密码（**从环境变量读，不要写死在脚本里**） |
| `OFFLINE_START` / `OFFLINE_END` | 断网时段，窗口内直接切换不再等 600 秒 |
| `PROBE_INTERVAL` | 在 4G 上时探测主线路的间隔（秒） |
| `AUTH_WAIT` | 主线路不通后等待多久才切（防抖，默认 600 秒） |

`MIHOMO_API` 指向本机代理内核的 REST 接口；不用 mihomo 的话把相关几行删掉即可，其余逻辑独立。

## 日志

```bash
journalctl -t wan-failover -n 50 --no-pager
```

正常的一夜长这样：

```
23:35:36  offline window + no internet -> switching
23:37:48  switch FAIL still no internet -> KEEP 4G route (avoid half-state), cooldown 300s
00:11:38  wifi reconnect: OK:MiFi-712D:60:192.168.9.197:200
00:11:55  mihomo back online after 1s
05:37:28  primary recovered -> switching back
05:37:52  switch back verified OK -> now on enp1s0
```

## 许可

MIT。

## 免责

脚本会改系统路由表，请在能物理接触到机器的环境里先测试。仅供个人自用。
