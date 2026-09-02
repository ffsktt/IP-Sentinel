# 🛡️ IP-Sentinel (Fork — Multi-IP / netns)

> Fork of [hotyue/IP-Sentinel](https://github.com/hotyue/IP-Sentinel) with multi-IP pool support and network namespace integration.

本 fork 在上游基础上新增：

- **Multi-IP 池化养护** — 单个 Agent 节点可同时轮转养护数百个 IP 地址
- **Network Namespace 集成** — 支持在 Linux netns 内运行，服务通过 `ip netns exec` 执行
- **CIDR 过滤** — 从 netns 接口地址中按前缀筛选需要养护的子集
- **有限并发** — 可配置的批量大小和并发数，串行轮转，不会产生高并发
- **代码/数据 URL 分离** — 代码 OTA 从本 fork 拉取，数据更新从上游拉取，rebase 零冲突

## 与上游的关系

| 内容 | 来源 |
|------|------|
| 代码 OTA (`REPO_RAW_URL`) | 本 fork (`ffsktt/IP-Sentinel`) |
| 数据更新 (`DATA_RAW_URL`) | 上游 (`hotyue/IP-Sentinel`) |
| 关键词/UA/区域规则 | 上游 GitHub Actions 每日生成 |
| 第三方 IP 探针 | `xykt/IPQuality`（独立） |

本 fork **不启用** GitHub Actions 的 scheduled workflows，避免产生数据 commit 导致 rebase 冲突。Agent 的 `updater.sh` 每日直接从上游拉取最新数据。

同步上游：

```bash
git remote add upstream https://github.com/hotyue/IP-Sentinel.git  # once
git fetch upstream
git rebase upstream/main
# REPO_RAW_URL 行（~3 处）是唯一可能的冲突点，trivial resolve
```

## 部署

### 前置条件

- 一台已部署 Master 的 VPS（或准备新装）
- TG Bot Token + Chat ID
- 目标 Edge 节点（VPS 或 netns 环境）

### Master（控制中枢）

**全新部署：**

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ffsktt/IP-Sentinel/main/master/install_master.sh)"
```

**从上游版本升级到 fork：**

```bash
# 1. 用 fork 的安装器覆盖（选"平滑升级"，保留数据库）
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ffsktt/IP-Sentinel/main/master/install_master.sh)"

# 2. 追加 fork URL 到 master.conf，确保后续 OTA 和版本检查指向 fork
echo 'REPO_RAW_URL="https://raw.githubusercontent.com/ffsktt/IP-Sentinel/main"' >> /opt/ip_sentinel_master/master.conf
systemctl restart ip-sentinel-master.service
```

### Edge 节点 — 普通 VPS（单 IP）

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ffsktt/IP-Sentinel/main/install.sh)"
```

按菜单选择地区、填入 TG 配置即可。与上游用法一致。

### Edge 节点 — netns 多 IP

适用于基于 netns 的部署环境，一个 netns 内 veth 接口上绑定了多个公网 IP。

在 host 上执行安装脚本：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ffsktt/IP-Sentinel/main/install.sh)"
```

安装过程中：
1. 选择 IP 时选"手动指定其他 IP"，填入 netns 中的一个主 IP（作为节点身份和 Master 通讯锚点）
2. 安装器会提示"是否在 netns 中运行"，选 `y` 后依次填入 netns 名称、接口名、CIDR 过滤规则
3. 安装完成后 systemd unit 自动带 `ip netns exec` 前缀

安装后如需修改参数（如 CIDR 过滤规则），直接编辑 `/opt/ip_sentinel/config.conf`。修改 `IP_POOL_FILTER` 等运行时参数**无需重启**（runner 每次执行重新读取 config）；修改 `NETNS_NAME` 需要重跑安装器升级模式以重建 systemd unit。

配置项说明：

| 配置项 | 说明 | 默认值 |
|--------|------|--------|
| `MULTI_IP_MODE` | `""` (禁用), `"netns"` (从接口枚举), `"list"` (显式列表) | `""` |
| `NETNS_NAME` | systemd unit 的 `ip netns exec` 参数 | `""` |
| `NETNS_IFACE` | netns 模式下扫描的接口名 | `veth0` |
| `IP_POOL` | list 模式的逗号分隔 IP 列表 | `""` |
| `IP_POOL_PROTO` | 协议过滤: `"4"`, `"6"`, 或留空（双栈） | `""` |
| `IP_POOL_FILTER` | CIDR include 过滤（逗号分隔前缀） | `""` |
| `IP_BATCH_SIZE` | 每次 runner 调度处理的 IP 数 | `5` |
| `IP_CONCURRENCY` | 并发养护槽位数 | `3` |

**验证**：

```bash
# 确认 unit 带 netns 前缀
grep ExecStart /etc/systemd/system/ip-sentinel-runner.service

# 手动触发一次
systemctl start ip-sentinel-runner.service
journalctl -u ip-sentinel-runner.service -n 30

# 检查轮转进度
cat /opt/ip_sentinel/core/.ip_pool_cursor
```

## 日常维护

| 操作 | 方法 |
|------|------|
| 修改 IP 池参数 | 编辑 `config.conf`，无需重启（runner 每次执行重新读取） |
| 修改 `NETNS_NAME` | 编辑 `config.conf` 后需重跑安装器升级模式以重建 systemd unit |
| 批量 OTA | Master TG 面板 → "全网节点 OTA 热重载" |
| 单节点 OTA | Master TG 面板 → 选节点 → "OTA 静默升级" |

## 卸载

```bash
bash /opt/ip_sentinel/core/uninstall.sh
```

## 上游文档

关于 Master-Agent 架构、模块功能、安全机制等详细说明，参见 [上游 README](https://github.com/hotyue/IP-Sentinel#readme)。

## 致谢

- [hotyue/IP-Sentinel](https://github.com/hotyue/IP-Sentinel) — 上游项目
- [xykt/IPQuality](https://github.com/xykt/IPQuality) — IP 质量探测脚本
