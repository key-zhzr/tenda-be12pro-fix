# Tenda BE12 Pro AN8855 / 三 WAN 修复验证

本仓库基于官方 ImmortalWrt `45474b1733debddfde8ce98ff2529b24cf9756ea`（Linux 6.18）维护补丁和编译流程。

2026-09-30 的两轮数据说明：最新调试固件中，lan3～lan5 可以同时协商 1Gbps；待修复的确定问题是三个独立 WAN 共用 MAC，造成 IPv6 DAD 失败，以及旧自定义板级配置错误生成 IPv6 接口。详见 [日志分析](docs/2026-09-30-findings.md)。这尚不等于三路数据传输已通过实机验收。

## 此次修改

- 保留 `0001` 的 PMCR / 流控修复；默认不应用高频 MDIO 调试日志和禁用 EEE 实验。
- lan3 / lan4 / lan5 分别使用独立、持久的设备 MAC 和 DHCPv4 / DHCPv6 客户端身份。
- 保留已有的有效独立 MAC；相同、无效或与 eth0/eth1/eth2 冲突的 MAC 从设备基地址确定性生成。
- 启用 `wan1/wan16`、`wan2/wan26`、`wan3/wan36` 双栈，metric 为 10 / 20 / 30；DHCPv6 请求 IA_NA，不请求 PD。
- 修复 `config_generate` 不支持板级 `protocol=dhcpv6` 的问题。
- 包含 LuCI、SQM、CAKE/IFB/tc、mwan3、SmartDNS 和常用诊断工具。
- WSL 和 GitHub Actions 使用同一套补丁及软件包配置脚本。
- 新增保持三口同时在线的只读采集工具，默认观察 60 秒。

## 先在现有固件上修复配置

当前日志里的固件已经含 `0001`，可以先应用配置修复，避免等待完整编译。将 `files/usr/libexec/be12pro-multiwan.sh` 和 `files/usr/bin/be12pro-netcheck.sh` 复制到路由器 `/tmp/`。

从原有的 LAN / Wi-Fi 管理连接执行：

```sh
sh /tmp/be12pro-multiwan.sh --apply

# 先启动采集，再应用新配置，可以记录 DHCP/RA/DAD 的启动过程。
sh /tmp/be12pro-netcheck.sh 120 &
CHECK_PID=$!
sleep 2
/etc/init.d/network reload
/etc/init.d/firewall reload
wait "$CHECK_PID"

sh /tmp/be12pro-multiwan.sh --check
```

`--apply` 在写入前备份 network/firewall 到 `/etc/be12pro-backups/时间-PID/`，不会自行重启网络。管理 LAN / Wi-Fi 配置、其它防火墙规则保持原有配置。若这三个口仍在管理桥中，或 wan1～wan3 指向其它设备，脚本会在写入前停止并提示冲突。

恢复备份时使用 `--apply` 输出的实际目录：

```sh
cp /etc/be12pro-backups/实际目录/network /etc/config/network
cp /etc/be12pro-backups/实际目录/firewall /etc/config/firewall
/etc/init.d/network reload
/etc/init.d/firewall reload
```

## WSL2 一键编译

在 Ubuntu / Debian WSL2 中用普通用户执行，编译目录放在 Linux 文件系统内。首次建议预留至少 40 GiB；脚本会安装依赖，并按可用内存限制默认并行任务数。

PR 合并前：

```bash
curl -fL https://raw.githubusercontent.com/key-zhzr/tenda-be12pro-fix/fix/multiwan-identity/build-be12pro-wsl.sh -o ~/build-be12pro-wsl.sh
bash ~/build-be12pro-wsl.sh
```

默认为 `PATCHSET=multiwan`。只有需要继续收集底层寄存器日志时，才选择：

```bash
PATCHSET=multiwan-mdio-debug RESET_SOURCE=1 bash ~/build-be12pro-wsl.sh
```

常用参数：

```bash
JOBS=4 bash ~/build-be12pro-wsl.sh
SKIP_DEPS=1 bash ~/build-be12pro-wsl.sh
PREPARE_ONLY=1 bash ~/build-be12pro-wsl.sh
EXTRA_PACKAGES='luci-app-ttyd ttyd' bash ~/build-be12pro-wsl.sh
# 合并后可以改用 main；首次切换源码/补丁可用新的 WORKROOT。
CONTROL_REF=main WORKROOT="$HOME/be12pro-main-wsl" bash ~/build-be12pro-wsl.sh
```

下载缓存、工具链和 ccache 会复用；源码/补丁变化时清理目标内核和根文件系统，避免继续使用旧驱动。切换补丁变体前需要 `RESET_SOURCE=1` 或新的 `WORKROOT`。`RESET_SOURCE=1` 会丢弃这个专用源码目录中的 tracked 修改，勿用于自己的开发目录。

产物位于 `~/be12pro-multiwan-wsl/output-时间/`，包含 sysupgrade、initramfs、配置、日志、源码及 feeds 版本、SHA256SUMS。源码固定到上述提交；feeds 更新到本次构建时的版本并记录 SHA。

### 默认接口布局

| 物理设备 | IPv4 | IPv6 | metric |
|---|---|---|---|
| eth1 / eth2 | 无默认逻辑接口 | 无默认逻辑接口 | — |
| lan3 | wan1：DHCP | wan16：DHCPv6 | 10 |
| lan4 | wan2：DHCP | wan26：DHCPv6 | 20 |
| lan5 | wan3：DHCP | wan36：DHCPv6 | 30 |

这是用户指定的三 WAN 布局。恢复出厂或 `sysupgrade -n` 后没有有线管理 LAN；Wi-Fi 也不会自动成为可用的管理入口。当前测试建议保留已有配置升级，不用 `-n`，先检查固件兼容性：

```sh
sysupgrade -T /tmp/实际固件文件名.bin
# 检查通过后，保留配置升级。
sysupgrade /tmp/实际固件文件名.bin
```

升级首启会运行身份修复；之后检查 `/etc/uci-defaults/99-be12pro-multiwan` 是否已成功执行（成功后该文件自动删除）。新固件中的工具可直接运行：

```sh
be12pro-netcheck.sh 120
```

安装 mwan3 不会自动配置负载均衡；这版首先验证三口独立工作。启用 SQM 时需按 OpenWrt 的要求关闭与整形冲突的 flow offloading。

## 验收与检查

1. 三个有效 MAC 不同；三口同时 `carrier=1`、`speed=1000`。
2. 不再出现 link-local `tentative dadfailed` / `IPv6 duplicate address`。
3. `wan16/wan26/wan36` 都是 `proto=dhcpv6`，各有独立 `clientid`。
4. 检查每口 DHCP 地址、网关邻居和绑定设备的探测结果；网关不回应 ICMP 时结合邻居表、抓包判断。
5. 收集脚本输出的 `/tmp/be12pro-netcheck-*.tar.gz`，核对每口的 DHCPv6 Solicit / Advertise / Reply 和 RA。

只有 `carrier=1` 或 HTTP 传输成功不足以证明校园认证成功。若 DAD 已解决，但仍只有 Solicit、没有 Advertise，继续检查上游校园接入策略、DHCPv6 中继和收发路径；配置修复不能保证上游允许三个接口同时登录。

本地 / CI 检查：

```bash
IMMORTALWRT_SOURCE=/path/to/immortalwrt python3 tests/test_multiwan.py
python3 tests/test_build_flow.py
bash scripts/prepare-source.sh /path/to/clean/immortalwrt multiwan
```

当前提交未包含本机编译完成的固件，也未完成硬件验收。
