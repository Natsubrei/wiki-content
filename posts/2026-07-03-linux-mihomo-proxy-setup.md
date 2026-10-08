---
title: "在 Linux 服务器上使用 Mihomo 配置命令行代理"
date: 2026-07-03
---

这篇笔记记录如何在无桌面环境的 Linux 服务器上安装 Mihomo，用 [mihomo-configs](https://github.com/Natsubrei/mihomo-configs) 生成配置，并做成命令行代理与 systemd 服务。

公开策略仓库**不提供节点**。订阅 URL 只写在仓库外的 `private.yaml`，不要 curl 成完整 `config.yaml`，也不要写进博客或脚本。

## 适用环境

- Linux 服务器或虚拟机，systemd
- x86_64 或 aarch64
- Python 3.11+（只在生成配置时需要；内核运行不需要）
- 已有可用的订阅链接

以下命令默认用 root。普通用户请按需加 `sudo`。

## 安装 Mihomo

取最新版本号：

```bash
MIHOMO_VERSION="$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/MetaCubeX/mihomo/releases/latest | sed 's#.*/##')"
echo "$MIHOMO_VERSION"
```

按架构选择包名。x86_64 用 `compatible` 构建，对偏旧的 glibc 更稳：

```bash
case "$(uname -m)" in
  x86_64)  MIHOMO_PKG="mihomo-linux-amd64-compatible" ;;
  aarch64) MIHOMO_PKG="mihomo-linux-arm64" ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

curl -L "https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/${MIHOMO_PKG}-${MIHOMO_VERSION}.gz" \
  -o /tmp/mihomo.gz
gzip -dc /tmp/mihomo.gz > /tmp/mihomo
chmod +x /tmp/mihomo
/tmp/mihomo -v
install -m 0755 /tmp/mihomo /usr/local/bin/mihomo
```

工作目录只给所有者：

```bash
install -d -m 700 /etc/mihomo
```

## 用私有文件生成配置

不要把订阅返回的整份 YAML 当作运行配置：它会带上对方的策略组、规则，还可能打开局域网和控制 API。正确做法是：仓库外一份只含订阅和本机参数的 `private.yaml`，用生成器合并公共策略。

```bash
git clone https://github.com/Natsubrei/mihomo-configs.git
cd mihomo-configs

python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt

cp -n examples/linux-private.yaml /etc/mihomo/private.yaml
chmod 600 /etc/mihomo/private.yaml
```

用编辑器打开 `/etc/mihomo/private.yaml`，把示例 `url` 换成自己的订阅。不要改仓库里的示例文件，也不要把真实 URL 写进命令行或 git。

示例使用 HTTP provider，间隔 3600 秒；首次下载默认 `proxy: DIRECT`，避免依赖尚未下载的自身节点。相对路径以 `mihomo -d` 的工作目录为准，即 `/etc/mihomo`。

生成到临时文件，校验后再安装：

```bash
python -m tools.render linux \
  --private /etc/mihomo/private.yaml \
  --output /etc/mihomo/config.next.yaml

mihomo -t -d /etc/mihomo -f /etc/mihomo/config.next.yaml
install -m 600 /etc/mihomo/config.next.yaml /etc/mihomo/config.yaml
```

生成器在目标已存在时默认拒绝覆盖，也不接受把 `private.yaml` 当成输出。需要替换已有 `config.yaml` 时，先备份，再考虑 `--force`。

默认结果：

- 混合端口 `127.0.0.1:7890`，不允许局域网
- 规则模式；无 TUN、无内置 DNS
- 控制 API 关闭
- 策略组大致为 `节点选择` → `自动选择`（当前能用则不追更快的节点），也可改 `故障转移` 或手动选节点；空动态组为 `REJECT`，不会悄悄变直连

完整说明见仓库 [`docs/linux.md`](https://github.com/Natsubrei/mihomo-configs/blob/main/docs/linux.md)。

## 配置 systemd 服务

```bash
vi /etc/systemd/system/mihomo.service
```

```ini
[Unit]
Description=Mihomo Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
LimitNPROC=500
LimitNOFILE=1000000
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now mihomo
systemctl status mihomo
```

生成器不会安装或重载这个服务。确认 `7890` 没被另一个进程占用；冲突时在 `private.yaml` 里改 `mixed-port` 后重新生成。

## 终端代理开关

在 `~/.bashrc` 增加：

```bash
alias proxy='export http_proxy=http://127.0.0.1:7890 https_proxy=http://127.0.0.1:7890 all_proxy=socks5://127.0.0.1:7890 HTTP_PROXY=http://127.0.0.1:7890 HTTPS_PROXY=http://127.0.0.1:7890 ALL_PROXY=socks5://127.0.0.1:7890 no_proxy=localhost,127.0.0.1,::1 NO_PROXY=localhost,127.0.0.1,::1'
alias unproxy='unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY'
```

```bash
source ~/.bashrc
proxy
curl -sS -o /dev/null -w '%{http_code}\n' -x http://127.0.0.1:7890 https://www.gstatic.com/generate_204
```

期望 `204`。`proxy` / `unproxy` 只影响当前 shell，不改 Mihomo 内部模式。这不是全局透明代理：默认没有 TUN，也不改系统 DNS。

## 更新

**只更新节点：** HTTP provider 由内核按 `interval` 拉取，一般不用重新生成。

**更新公共策略或本机参数：**

```bash
cd /path/to/mihomo-configs
git pull --ff-only
source .venv/bin/activate
python -m pip install -r requirements.txt
python -m tools.render linux \
  --private /etc/mihomo/private.yaml \
  --output /etc/mihomo/config.next.yaml
mihomo -t -d /etc/mihomo -f /etc/mihomo/config.next.yaml
```

校验通过后备份旧 `config.yaml`，再替换并 `systemctl restart mihomo`。不要用订阅 URL 覆盖 `config.yaml`。

`mihomo -t` 只检查配置，不保证节点可用或规则下载成功。失败时保留 `providers/`、`ruleset/` 里的有效缓存。

## 控制 API（可选）

默认关闭。若要在本机切模式或节点，在 `private.yaml` 里启用回环地址，并设置至少 16 字符的随机 `secret`，然后重新生成：

```yaml
external-controller: '127.0.0.1:9090'
secret: '请替换为本地生成的强随机密钥'
```

之后请求都要带令牌，例如：

```bash
curl --noproxy '*' -sS http://127.0.0.1:9090/configs \
  -H "Authorization: Bearer ${MIHOMO_SECRET}"
```

切到规则模式：

```bash
curl --noproxy '*' -sS -X PATCH http://127.0.0.1:9090/configs \
  -H "Authorization: Bearer ${MIHOMO_SECRET}" \
  -H 'Content-Type: application/json' \
  -d '{"mode":"rule"}'
```

主选择组是 `节点选择`，默认用 `自动选择`。名称含中文时路径要做 URL 编码：

```bash
# 节点选择 → 自动选择
curl --noproxy '*' -sS -X PUT \
  "http://127.0.0.1:9090/proxies/%E8%8A%82%E7%82%B9%E9%80%89%E6%8B%A9" \
  -H "Authorization: Bearer ${MIHOMO_SECRET}" \
  -H 'Content-Type: application/json' \
  -d '{"name":"自动选择"}'
```

不要把控制口绑到非回环地址，也不要空 `secret`。

## 常见问题

- 生成器报目标已存在：先备份，改输出到 `config.next.yaml`，或确认后使用 `--force`。
- 订阅直连拉不下来：需要一个已经可用的下载路径，或先下载节点文件改用 `type: file`。工具不会解开「用自身节点下载自身订阅」的环。
- 空组或流量被拒绝：动态组没有候选时是 `REJECT`。先看 `private.yaml` 的 provider 是否拉到真实节点，而不是公告/流量说明条目。
- 不要把订阅下发的完整配置当作 `private.yaml`：含 `rules` / `proxy-groups` 时生成器会拒绝。

## 安全建议

- 订阅 URL 中的 `token` 等同凭据。泄露后在服务商处重置。
- `/etc/mihomo/private.yaml`、`config.yaml`、`providers/` 留在仓库外，权限 `600`。
- 默认只监听 `127.0.0.1:7890`。不要为了省事打开 `allow-lan`。
- 公开文章里不要出现真实订阅域名、token、UUID、密码或节点地址。
