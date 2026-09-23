---
title: "使用 Docker Compose 部署 SFTPGo 文件仓库"
date: 2026-07-15
---

> 文中的 `192.0.2.0/24` 为文档示例网段，部署时请替换为实际服务器地址。

## 1. 文档说明

本文档用于在 `192.0.2.20` 上通过 Docker Compose 部署和维护 SFTPGo 文件仓库。

示例部署基线：

| 项目 | 配置 |
| --- | --- |
| 服务器 | `192.0.2.20` |
| CPU 架构 | ARM64（aarch64） |
| 部署方式 | Docker Compose |
| SFTPGo 版本 | `2.7.1` Community Edition |
| Web 管理端口 | `19080` |
| SFTP 端口 | `12022` |
| Compose 目录 | `/opt/file-repository` |
| 配置及数据库 | `/opt/file-repository/config` |
| 文件数据 | `/opt/file-repository/data` |
| 容器名称 | `sftpgo`、`sftpgo-web` |
| Web 反向代理 | nginx `1.28.0`，提供入口重定向及 WebClient 登录页会话保护 |
| Web 会话有效期 | 最长 12 小时（`cookie_lifetime=720`，不等于保证所有情况下免登录，见第 15 节） |

管理页面：

```text
http://192.0.2.20:19080/web/admin
```

用户文件页面（导航卡片、书签使用这个地址）：

```text
http://192.0.2.20:19080/web/client/files
```

> SFTPGo `2.7.1` 的 `/web/client` 会无条件跳转登录页；重新打开登录页还可能覆盖已有会话 cookie。本文通过 nginx 保护 WebClient 登录入口，解决“刚登录，再点导航卡片或恢复旧标签页就要重新登录”的问题。根因和验证方法见第 15 节。

## 2. 部署架构

```text
浏览器
  └─ HTTP 19080 ──> nginx :80 ──> SFTPGo :8080
                      │           ├─ WebAdmin
                      │           └─ WebClient
                      └─ 登录页 GET：先用内部子请求验证会话
                          ├─ 有效：转到文件页，不覆盖 cookie
                          └─ 无效：正常显示登录页

SFTP 客户端
  └─ TCP 12022 ──> SFTPGo SFTP 2022

192.0.2.20
  ├─ /opt/file-repository/docker-compose.yml
  ├─ /opt/file-repository/nginx.conf
  ├─ /opt/file-repository/config
  │    ├─ sftpgo.db
  │    └─ SSH Host Keys
  └─ /opt/file-repository/data
       ├─ data/<用户名>
       ├─ shared
       └─ backups
```

容器删除或重新创建后，只要 `/opt/file-repository` 完整保留，用户、权限、配置和文件数据仍然存在。

## 3. 部署前检查

### 3.1 检查系统环境

```bash
uname -m
docker version
docker compose version
df -h /opt
```

确保：

- CPU 架构为 `aarch64` 或 `arm64`。
- Docker 和 Docker Compose 可以正常使用。
- `/opt` 有足够磁盘空间。
- `19080` 和 `12022` 未被其他服务占用。

```bash
ss -lntp | grep -E ':19080|:12022'
```

### 3.2 启用 Docker 开机自启

```bash
systemctl enable --now docker
systemctl is-enabled docker
systemctl is-active docker
```

### 3.3 创建持久化目录

SFTPGo 容器使用 UID/GID `1000:1000` 运行：

```bash
install -d -o 1000 -g 1000 -m 0750 /opt/file-repository/config
install -d -o 1000 -g 1000 -m 0750 /opt/file-repository/data
```

在宿主机上，目录所有者会显示为 UID `1000` 对应的本地用户名，这是正常的 UID 映射结果。不要对数据目录执行 `chmod -R 777`。

## 4. Docker Compose 与 nginx 配置

先创建下面两个文件，再启动容器。不要只复制 Compose 而遗漏 `nginx.conf`，否则 Docker 可能把缺失的挂载源创建成目录。

### 4.1 Docker Compose

创建 `/opt/file-repository/docker-compose.yml`：

```yaml
services:
  sftpgo:
    image: drakkan/sftpgo:v2.7.1
    container_name: sftpgo
    restart: always
    environment:
      # Web 界面登录保持时长，单位为分钟，最大 720（12 小时），详见第 15 节
      SFTPGO_HTTPD__COOKIE_LIFETIME: "720"
      # 可选：客户端 IP 会变化（多出口 NAT、VPN、DHCP）时启用，取消 cookie 与 IP 的绑定
      # SFTPGO_HTTPD__TOKEN_VALIDATION: "1"
      # 只信任本 Compose 专用网络中的反向代理，与下方 IPAM 子网保持一致
      SFTPGO_HTTPD__BINDINGS__0__PROXY_ALLOWED: "172.30.90.0/24"
      SFTPGO_HTTPD__BINDINGS__0__CLIENT_IP_PROXY_HEADER: "X-Forwarded-For"
      SFTPGO_HTTPD__BINDINGS__0__CLIENT_IP_HEADER_DEPTH: "0"
    ports:
      # 不发布后端 HTTP 8080，由 nginx 通过容器网络访问
      - "192.0.2.20:12022:2022"
    volumes:
      - /opt/file-repository/config:/var/lib/sftpgo
      - /opt/file-repository/data:/srv/sftpgo
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"

  web:
    image: nginx:1.28.0-alpine
    container_name: sftpgo-web
    restart: always
    depends_on:
      - sftpgo
    ports:
      - "192.0.2.20:19080:80"
    volumes:
      - /opt/file-repository/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    security_opt:
      - no-new-privileges:true
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"

networks:
  default:
    ipam:
      config:
        - subnet: "172.30.90.0/24"
```

配置说明：

- 镜像固定到本文验证的版本，而不是跟随 `latest` 或 `stable` 漂移；长期运行仍需按第 13 节评估安全更新。
- 对外 Web 和 SFTP 端口只绑定业务 IP。不向宿主机发布 SFTPGo 的后端 HTTP `8080`，它仅通过容器网络供 nginx 访问，避免额外暴露绕过会话保护的入口。
- `172.30.90.0/24` 是容器内部专用的示例子网，不是服务器业务地址。先确认它与宿主机、VPN 和现有 Docker 网络不冲突；如需修改，应同时修改 IPAM 与 `PROXY_ALLOWED`。不要把不可信容器接入该网络，也不要把可信代理范围写成 `0.0.0.0/0`。
- nginx 覆盖 `X-Forwarded-For` 为直连客户端地址；SFTPGo 只信任上述网络的转发头，日志及基于 IP 的校验仍使用真实客户端地址。
- `restart: always` 用于服务器重启后自动恢复；`no-new-privileges` 阻止通过 setuid 等方式获得额外权限。
- 每个容器的 Docker 日志最多保留 5 个文件，每个文件最大 20 MB。
- `COOKIE_LIFETIME` 控制 Web 会话时长，默认 20 分钟，示例取 720 分钟。它不能阻止登录页覆盖会话 cookie。
- `TOKEN_VALIDATION=1` 仅在客户端 IP 确实会变化时启用，不是会话保护方案的必需项，详见第 15 节。

### 4.2 nginx 配置

创建 `/opt/file-repository/nginx.conf`：

```nginx
server {
    listen 80;
    server_name _;

    # 返回相对 Location，避免用容器内端口 80 替代外部端口 19080
    absolute_redirect off;

    # 支持大文件，不在 nginx 层限制请求体大小或缓冲整个上传
    client_max_body_size 0;
    proxy_request_buffering off;
    proxy_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_http_version 1.1;
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_cookie_flags jwt samesite=lax;

    # SFTPGo 2.7.1 的 /web/client 无条件跳登录页，改为进入文件页
    location = / {
        add_header Cache-Control "no-store" always;
        return 302 /web/client/files;
    }
    location = /web/client {
        add_header Cache-Control "no-store" always;
        return 302 /web/client/files;
    }

    # 重新打开登录页时，先由 SFTPGo 验证已有会话
    location = /web/client/login {
        # 非 GET 请求原样转发；命名 location 保留 POST 方法、正文和查询参数
        error_page 418 = @sftpgo;
        if ($request_method != GET) { return 418; }

        auth_request /_sftpgo_session_check;
        error_page 401 403 = @sftpgo;
        # 在访问控制阶段完成后，转到已登录入口；不要改成直接 return
        try_files /.__sftpgo_session_guard_no_file__ @sftpgo_signed_in;
    }

    location = /_sftpgo_session_check {
        internal;
        proxy_pass http://sftpgo:8080/web/client/ping;
        proxy_method GET;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        # 本层声明 proxy_set_header 后，须重新列出所需转发头
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 5s;
        proxy_read_timeout 10s;
        proxy_intercept_errors on;
        # 未认证的 ping 返回重定向，转换为 auth_request 能处理的 401
        error_page 301 302 303 307 308 = @sftpgo_no_session;
    }
    location @sftpgo_no_session {
        return 401;
    }
    location @sftpgo_signed_in {
        add_header Cache-Control "no-store" always;
        return 302 /web/client/files;
    }
    location @sftpgo {
        proxy_pass http://sftpgo:8080;
    }
    location / {
        proxy_pass http://sftpgo:8080;
    }
}
```

这份配置的边界：

- `auth_request` 使用的是受 WebClient 认证保护的 `/web/client/ping`，不是公开健康检查。nginx 不自行判断 JWT 内容，也不因为“存在 cookie”就放行。
- 内部验证 URL 对外返回 `404`；后端异常不会被当成认证成功。
- `418` 仅用于 nginx 内部跳转，正常登录提交不会收到这个状态码。登录 POST 仍由 SFTPGo 校验密码、CSRF 等信息。
- 不要将登录页 location 中的 `try_files` 简化成 `return 302`：`return` 在 rewrite 阶段执行，会早于访问控制阶段的 `auth_request`。
- 登录页保护仅覆盖 **WebClient 的 GET 登录页**，没有改写 WebAdmin 登录流程；其他请求仍正常代理。
- 此处 nginx 是浏览器的直接入口。如果前面还有 HTTPS 网关，必须另行配置可信代理、真实 IP 和协议传递，不能直接信任用户提交的转发头。
- `client_max_body_size 0` 只是取消 nginx 的请求体上限；SFTPGo 的权限、配额和文件限制仍然有效。超时参数按业务需求调整。

## 5. 启动与验证

### 5.1 启动服务

```bash
cd /opt/file-repository
test -f nginx.conf
docker compose config
docker compose pull
docker compose up -d
docker compose exec web nginx -t
docker compose ps
```

### 5.2 检查日志

```bash
docker compose logs --tail 200 sftpgo web
```

首次启动时，SFTPGo 会创建：

- SQLite 数据库 `sftpgo.db`。
- RSA、ECDSA 和 ED25519 SSH Host Key。
- 初始数据库表结构。

日志中首次出现 `no such table` 后紧接着创建数据库结构，属于首次初始化过程，并非持续故障。

### 5.3 验证运行状态

```bash
docker inspect sftpgo \
  --format 'status={{.State.Status}} restart={{.RestartCount}} policy={{.HostConfig.RestartPolicy.Name}}'

curl -I http://192.0.2.20:19080/web/admin
ss -lntp | grep -E ':19080|:12022'
```

正常情况下：

- `docker compose ps` 中 `sftpgo` 和 `web` 均在运行，重启策略为 `always`。
- `/web/admin` 跳转到管理员登录或首次初始化页面。
- `19080` 和 `12022` 均处于监听状态。

完成首次管理员初始化后，再检查普通用户入口（此时 curl 没有登录会话）：

```bash
curl -sS -o /dev/null -D - http://192.0.2.20:19080/
# 预期：302，Location: /web/client/files（相对地址，不丢失 19080 端口）

curl -sS -L -o /dev/null -w '%{http_code} %{url_effective}\n' \
  http://192.0.2.20:19080/web/client/files
# 预期：200，最终 URL 为登录页；不是无需认证就能访问文件
```

这些检查只能证明服务可达及未登录路径正常，不能证明浏览器会话保持正常。登录后的完整验证见第 15.7 节。

## 6. 首次初始化

首次访问：

```text
http://192.0.2.20:19080/web/admin/setup
```

按照页面提示创建第一个管理员账号。管理员密码应：

- 使用高强度独立密码。
- 不写入 Compose、脚本或代码仓库。
- 在条件允许时启用双因素认证。

管理员后台和用户页面不同：

| 页面 | 用途 |
| --- | --- |
| `/web/admin` | 管理用户、Group、Folder、权限和服务配置 |
| `/web/client/files` | 普通用户上传、下载、分享和管理文件；未登录时自动进入登录页 |

SFTPGo Community 的官方界面语言不包含中文（WebAdmin 目前仅提供英语和意大利语）。可使用浏览器的网页翻译功能，后端功能不受影响。

## 7. 创建文件用户

进入：

```text
WebAdmin → Users → +
```

至少填写：

- Username：用户登录名。
- Password 或 Public Keys：认证凭据。
- Home Dir：可留空使用默认规则，也可明确设置为 `/srv/sftpgo/data/<用户名>`。
- Permissions：根据需要授予上传、下载、删除等权限。
- Quota：根据用户用途设置容量和文件数量限制。

SFTP 登录示例：

```bash
sftp -P 12022 <用户名>@192.0.2.20
```

用户文件入口：

```text
http://192.0.2.20:19080/web/client/files
```

建议导航卡片和书签直接使用文件入口，而不是 `/web/client/login`。本文的 nginx 配置同时保护了误开登录页、恢复旧登录标签页的场景。

## 8. Group 与共享目录

### 8.1 Group 类型

| Group 类型 | 作用 |
| --- | --- |
| Primary | 每个用户最多一个，提供主目录、默认权限、配额等基础配置 |
| Secondary | 每个用户可以多个，用于追加共享目录、权限和过滤规则 |
| Membership | 只记录成员关系，不继承目录和权限 |

加入同一个 Group 不会自动共享用户各自的主目录。共享文件应使用 Virtual Folder，并通过 Primary 或 Secondary Group 分配给用户。

### 8.2 创建共享 Folder

进入：

```text
WebAdmin → Folders → +
```

示例配置：

| 字段 | 值 |
| --- | --- |
| Name | `team-shared` |
| Storage | Local filesystem |
| Absolute path | `/srv/sftpgo/shared/team` |
| Quota size | `0`，表示不限制 |
| Quota files | `0`，表示不限制 |

容器内路径：

```text
/srv/sftpgo/shared/team
```

对应主机路径：

```text
/opt/file-repository/data/shared/team
```

### 8.3 创建共享 Group

进入：

```text
WebAdmin → Groups → +
```

创建 `team` Group，在 Virtual Folders 中添加：

| 字段 | 值 |
| --- | --- |
| Folder | `team-shared` |
| Virtual path | `/shared` |
| Quota size/files | `0` |

在 ACL/Permissions 中为 `/shared` 设置权限：

- 完全读写：选择 `*`。
- 只读：只选择 `list` 和 `download`。
- 只允许上传：按实际需要选择 `list`、`upload`、`create_dirs` 等权限。

### 8.4 将用户加入 Group

进入：

```text
WebAdmin → Users → Edit → Secondary Groups
```

将 `team` 添加为 Secondary Group。用户重新登录后会看到：

```text
/
├── 用户自己的文件
└── shared
    └── Group 共享文件
```

所有成员访问的是同一个实际目录，一个成员上传的文件会立即对其他有权限的成员可见。

共享 Virtual Folder 不要设置成“计入单个用户配额”，否则多个用户共享时配额统计可能不准确。应为 Folder 使用独立配额。

如果需要读写组和只读组，可以创建 `team-rw` 与 `team-ro` 两个 Secondary Group，都映射同一个 Folder 到 `/shared`，但配置不同 ACL。不要让同一用户同时加入两个在相同 Virtual path 上定义不同映射的 Group。

## 9. 日常运维

```bash
cd /opt/file-repository

# 状态
docker compose ps

# 实时日志
docker compose logs -f --tail 200 sftpgo web

# 仅修改 nginx.conf 后：先检查，再平滑重载，不重启 SFTPGo
docker compose exec web nginx -t && docker compose exec web nginx -s reload

# 重启应用进程（未固定签名密钥时，现有 Web 会话会失效）
docker compose restart sftpgo

# 停止整个文件仓库入口及后端
docker compose stop

# 启动
docker compose start

# 按 Compose 更新全部服务；后端重建后让 nginx 重新解析服务地址
docker compose up -d
docker compose exec web nginx -t && docker compose exec web nginx -s reload
```

查看资源使用：

```bash
docker stats --no-stream sftpgo sftpgo-web
du -sh /opt/file-repository/config /opt/file-repository/data
df -h /opt
df -ih /opt
```

只修改 bind mount 中的 `nginx.conf` 后，`docker compose up -d web` 不保证 nginx 进程重读配置；必须执行 `nginx -t` 和 `nginx -s reload`。如果 SFTPGo 重建后容器 IP 变化，也需重载 nginx，避免它继续连接旧地址。

Docker 发布端口与宿主机防火墙规则之间存在交互，不能仅凭 firewalld 的端口列表断言端口是否可达。应从真实客户端测试，并按 Docker 所用的 iptables/nftables 后端配置入口访问控制，不要为排障直接关闭防火墙。

## 10. 开机自动恢复

检查 Docker 服务和容器重启策略：

```bash
systemctl is-enabled docker
systemctl is-active docker
docker inspect sftpgo sftpgo-web --format '{{.Name}} {{.HostConfig.RestartPolicy.Name}}'
```

预期结果为：

- Docker：`enabled`、`active`。
- 两个容器的重启策略：`always`。

服务器重启后检查：

```bash
docker ps --filter name=sftpgo
curl -I http://192.0.2.20:19080/web/admin
```

## 11. 数据备份

### 11.1 备份内容

必须同时备份：

1. `/opt/file-repository/config`：数据库、SSH Host Key 和服务状态。
2. `/opt/file-repository/data`：所有用户文件和共享文件。
3. `/opt/file-repository/docker-compose.yml`：部署配置。
4. `/opt/file-repository/nginx.conf`：反代入口及会话保护配置。

只备份文件目录而不备份数据库，会丢失用户、密码哈希、Group、Folder 和权限关系。

### 11.2 一致性备份

SQLite 数据库适合在短暂停止服务后进行文件级备份：

```bash
cd /opt/file-repository
docker compose stop

tar -C /opt -czf /opt/sftpgo-backup-$(date +%F-%H%M%S).tar.gz \
  file-repository/config \
  file-repository/data \
  file-repository/docker-compose.yml \
  file-repository/nginx.conf

docker compose start
```

确认服务恢复：

```bash
docker compose ps
curl -I http://192.0.2.20:19080/web/admin
```

### 11.3 备份原则

- 备份必须复制到另一台服务器、独立磁盘或对象存储。
- 仅放在 `/opt` 同一块磁盘上的备份不能防止磁盘损坏。
- 备份中包含密码哈希和 SSH Host Key，应限制访问权限并加密保存。
- 定期执行恢复演练。
- 备份前确认磁盘剩余空间。

## 12. 数据恢复

恢复会覆盖当前服务数据，应在维护窗口执行。

```bash
cd /opt/file-repository
docker compose stop
```

将当前目录保留为恢复前快照，再从备份中恢复 `config`、`data`、Compose 文件和 `nginx.conf`。恢复后检查权限：

```bash
chown -R 1000:1000 /opt/file-repository/config
chown -R 1000:1000 /opt/file-repository/data
chmod 0750 /opt/file-repository/config
chmod 0750 /opt/file-repository/data
```

启动并验证：

```bash
cd /opt/file-repository
docker compose config
docker compose up -d
docker compose exec web nginx -t && docker compose exec web nginx -s reload
docker compose logs --tail 200 sftpgo web
curl -I http://192.0.2.20:19080/web/admin
```

恢复后应验证：

- 管理员能够登录。
- 用户和 Group 配置存在。
- 用户自己的目录可以访问。
- Group 共享目录可以读写。
- SFTP Host Key 未意外改变。
- nginx 配置检查通过，文件入口、登录页保护和真实客户端 IP 正常（见第 15.7 节）。

## 13. 版本升级

升级原则：

- 不使用 `latest`。
- 升级前备份配置、数据库和文件数据。
- 阅读目标版本 Release Notes，特别关注数据库迁移和不兼容变更。
- 先在测试环境验证，再升级生产实例。

升级步骤：

```bash
cd /opt/file-repository

# 完成备份后，修改 docker-compose.yml 中的固定版本
docker compose config
docker compose pull sftpgo
docker compose up -d sftpgo
docker compose exec web nginx -t && docker compose exec web nginx -s reload

docker compose logs --tail 200 sftpgo web
docker inspect sftpgo --format '{{.State.Status}} {{.RestartCount}}'
```

升级 nginx 时，单独更新 `web.image` 的固定版本，再执行 `docker compose pull web`、`docker compose up -d web` 和 `docker compose exec web nginx -t`。自行构建 nginx 镜像时，确认包含 `http_auth_request_module`。

两类升级都应重新执行第 15.7 节的浏览器回归测试。本文对登录页行为的分析针对 SFTPGo `2.7.1`；新版本可能改变路由、cookie 或认证接口，不能只确认容器启动成功。

不要只依赖旧镜像回滚。若新版本已迁移数据库，应使用升级前完整备份恢复。

重建容器会让所有已登录的 Web 会话立即失效（未配置 `signing_passphrase` 时，签名密钥每次启动随机生成），用户需要重新登录一遍。若希望跨重启保留会话，可先按第 15.4 节配置固定签名密钥。

## 14. HTTPS 与安全加固

示例 Web 地址使用 HTTP：

```text
http://192.0.2.20:19080
```

HTTP 会明文传输登录凭据和文件内容，不应直接暴露到公网或不可信网络。

生产使用建议：

- 配置域名，例如 `files.example.internal`。
- 在本文 nginx 上配置 TLS，或在它前面使用可信的 HTTPS 网关；本示例的 HTTP 反代本身不提供加密。
- 使用客户端信任的内部 CA 或正式 CA 证书。
- 防火墙仅允许受信任网段访问 `19080` 和 `12022`。
- 管理员启用双因素认证。
- 普通用户优先使用 SSH 公钥认证。
- 为用户和共享 Folder 设置合理配额。
- 定期检查失败登录和封禁记录。
- 不向普通用户授予不必要的删除、覆盖和分享权限。
- 定期升级到包含安全修复的版本。
- 仅在客户端 IP 确实会变化时放宽 cookie 的来源 IP 校验，并确保入口为 HTTPS（见第 15 节）。

本文不向宿主机发布 SFTPGo 后端 HTTP 端口，业务 IP 上的 `19080` 由 nginx 提供。若在前面另加 HTTPS 网关，应只允许该网关访问 nginx 的 HTTP 入口，避免绕过 HTTPS。

增加上游网关时，要同步调整可信代理链及 `X-Forwarded-Proto`、真实客户端 IP 的解析。不能在 HTTP 后端一律覆盖成 `$scheme` 后仍假定 SFTPGo 看到了 HTTPS，也不能无条件信任外部传入的 `X-Forwarded-For`。

## 15. 会话有效期与登录保持

本文讨论 SFTPGo 内置表单登录，OIDC 等单点登录流程需单独验证。WebAdmin 和 WebClient 使用服务端签发的 JWT cookie；正常的持久 cookie 可以跨浏览器重启保存，但隐私模式、清除站点数据、退出登录、签名密钥变化或 cookie 被覆盖，都会影响登录状态。

**“再次看到登录页”不等于“cookie 已过期”。** 本文遇到的故障是：登录成功后，重新打开登录页把 WebClient 会话 cookie 替换成了 WebLogin cookie。延长有效期、取消 IP 校验都无法阻止这次替换；应先按第 15.5 节区分原因，再调整时长。

### 15.1 会话相关配置项

| 配置项 | 默认值 | 上限 | 作用 |
| --- | --- | --- | --- |
| `httpd.cookie_lifetime` | 20 分钟 | 720 分钟 | WebAdmin / WebClient 的登录 cookie 有效期 |
| `httpd.jwt_lifetime` | 20 分钟 | 720 分钟 | REST API token 有效期 |
| `httpd.share_cookie_lifetime` | 120 分钟 | 720 分钟 | 公开分享链接的 cookie 有效期 |
| `httpd.token_validation` | `0` | — | cookie 与 token 的校验方式 |
| `httpd.signing_passphrase` | 空 | — | JWT 签名密钥，决定重启后会话是否保留 |

对应的环境变量为 `SFTPGO_HTTPD__COOKIE_LIFETIME` 等，配置层级用双下划线分隔。表中前三项时长的合法范围为 `1` 到 `720` 分钟；超范围时不会按更长时长生效，而会保留默认值。

### 15.2 cookie_lifetime 与 12 小时硬上限

文件页等支持续期的 Web 请求可以触发 cookie 刷新，但时间上受两个条件约束：

1. 只有剩余时间小于或等于 `cookie_lifetime / 2` 时才触发续期。
2. 从首次签发算起，会话总时长不能超过 12 小时（源码常量 `maxTokenDuration`，无法通过配置修改）。

两个条件必须同时成立。以首次续期为例，**只有 `cookie_lifetime` 小于 480 分钟时才存在正宽度的续期窗口**：

```text
触发续期：登录至今 ≥ L / 2
允许续期：登录至今 ≤ 720 - L        （L 为 cookie_lifetime，单位分钟）

窗口宽度为 720 - 1.5 × L，要求为正，即 L < 480
```

- `L = 20`（默认）：活跃请求可以触发续期，总时长不超过 12 小时；无请求时，剩余有效期耗尽就需要重新登录。
- `L = 480`：两个条件恰好交于同一点，没有实际可用的续期窗口，通常表现为**固定 8 小时到期**，持续操作也无法延长。这是容易踩的坑。
- `L = 720`：cookie 直接有效 12 小时，不再依赖续期；适合关闭浏览器后隔一段时间再打开的场景。

| `cookie_lifetime` | 单次签发 / 续期后的有效期 | 活跃会话总时长上限 | 适用场景 |
| --- | --- | --- | --- |
| `20`（默认） | 20 分钟 | 12 小时 | 安全优先 |
| `240` | 4 小时 | 12 小时 | 日常使用折中 |
| `720` | 12 小时 | 12 小时 | 低频访问，关闭浏览器后仍保持登录 |

有效期从签发或续期时计算，不是每个请求都重置倒计时。因此停止操作时，剩余有效期可能已小于表中的数值；持续活跃也不保证恰好在第 12 小时才失效。

无论取何值，**12 小时的会话总时长上限都无法通过配置突破**。超过 12 小时必须重新登录，这是 SFTPGo 的固定行为；需要更长会话时，只能改用 SFTP、FTP、WebDAV 等客户端，或自行修改源码构建镜像。

### 15.3 token_validation

```text
0（默认）  cookie 和 token 必须与签发时的客户端 IP 一致
1          取消 IP 一致性校验
2          额外校验账号最后修改时间，管理员或用户被修改后旧 cookie 立即失效
3          1 和 2 的组合
```

默认值 `0` 意味着客户端 IP 一旦变化（多出口 NAT、VPN、切换无线与有线、DHCP 重新分配）会话就立即失效，表现为操作过程中突然跳回登录页。这类环境可设置为 `1` 或 `3`。

代价是 cookie 不再绑定来源 IP，一旦泄露，在有效期内可能被其他地址复用。因此只在客户端 IP 确实会变化时启用，并使用 HTTPS、保留 `HttpOnly` 和 SFTPGo 的 CSRF 校验，限制入口可访问范围。

SFTPGo `2.7.1` 默认设置 `SameSite=Strict`；本文 nginx 将其改为 `Lax`，以允许跨站顶级 GET 导航携带 cookie。`Lax` 比 `Strict` 宽松，不应把它当成完整的 CSRF 防护，也不需要为此进一步改成 `SameSite=None`。

### 15.4 signing_passphrase：避免重启后集体登出

未配置 `httpd.signing_passphrase` 时，SFTPGo 每次启动都会随机生成 JWT 签名密钥，因此**每次重建容器都会让全部会话失效**。需要跨重启保留登录状态时，使用固定密钥：

```bash
openssl rand -base64 32
```

生成的字符串可写入 Compose：

```yaml
    environment:
      SFTPGO_HTTPD__SIGNING_PASSPHRASE: "<openssl rand -base64 32 的输出>"
```

也可以写入文件后通过 `SFTPGO_HTTPD__SIGNING_PASSPHRASE_FILE` 引用（路径相对配置目录，例如 `/var/lib/sftpgo/signing_passphrase`），避免密钥出现在 `docker inspect` 输出里：

```bash
install -o 1000 -g 1000 -m 0400 /dev/null /opt/file-repository/config/signing_passphrase
openssl rand -base64 32 > /opt/file-repository/config/signing_passphrase
```

```yaml
    environment:
      SFTPGO_HTTPD__SIGNING_PASSPHRASE_FILE: "signing_passphrase"
```

密钥本身要纳入备份，并连同备份一起加密保存。修改密钥会让当前所有会话失效一次。

### 15.5 刚登录就被要求重登：登录页覆盖会话

以下行为已通过 SFTPGo `2.7.1` 源码及浏览器测试确认：

1. 普通用户登录成功，服务端下发 `jwt` cookie，JWT audience 包含 `WebClient`，Path 为 `/web/client`。
2. GET `/web/client/login` 时，服务端不会先验证并保留已有的 WebClient 会话，而是直接渲染登录页。
3. 为登录表单生成 CSRF 凭证时，服务端设置一个 audience 为 `WebLogin` 的 cookie。它的名称仍是 `jwt`、Path 仍是 `/web/client`，所以会替换浏览器中的 WebClient 会话 cookie。
4. 再访问 `/web/client/files`，WebLogin 不满足文件页的认证要求，于是需要重新登录。

```text
登录成功                         jwt: WebClient
  → 重新打开 /web/client/login    jwt: WebLogin（同名同路径，覆盖）
  → 再访问文件页                 要求重新登录
```

这不需要等待过期，也不要求 IP 变化或浏览器清除 cookie。旧标签页恢复、历史记录、书签或其他入口如果再次请求登录页，都可能触发它。不能仅凭日志中的 `cookie=yes` 判定该请求带着有效会话。

还有两个容易混淆的因素：

- **入口路由**：`/web/client` 在该版本中无条件重定向到登录页，不是“它校验了 cookie，但拒绝了会话”。同一个有效会话访问 `/web/client/files` 可以正常进入。因此导航和书签应指向文件页。
- **跨站携带**：从另一个站点的导航页点击进入时，默认的 `SameSite=Strict` 可能阻止 cookie 随首轮导航发送。改为 `Lax` 解决携带问题，但不能阻止之后重新打开登录页覆盖 cookie。

浏览器不会向根路径 `/` 发送 Path 为 `/web/client` 的 cookie，这是正常的路径匹配规则；解决方法是让入口转到受保护的文件页，而不是把 WebAdmin、WebClient 的 cookie 路径都改成 `/`。

### 15.6 nginx 如何保护登录页

第 4.2 节的配置处理三个独立问题：

| 处理 | 目的 |
| --- | --- |
| `/`、`/web/client` → `/web/client/files` | 避免默认入口无条件进入登录页 |
| `proxy_cookie_flags jwt samesite=lax` | 允许从其他站点的顶级 GET 导航携带 cookie |
| GET 登录页先执行 `auth_request` | 防止有效会话被登录页的 WebLogin cookie 覆盖 |

最关键的是第三项：

```text
GET /web/client/login（包括带 next 参数的请求）
  → nginx 内部 GET /web/client/ping，转发原请求 cookie
      ├─ SFTPGo 验证成功（2xx）
      │    → 302 /web/client/files，不渲染登录页、不覆盖 cookie
      └─ 未认证（重定向转换为 401，或直接返回 401/403）
           → 正常代理登录页，让用户登录

POST /web/client/login
  → 原样转发给 SFTPGo，正常校验登录表单
```

这不是根据 cookie 是否存在或解码后的 audience 来放行。签名、有效期、退出后的令牌失效状态等认证判断，仍由 SFTPGo 完成。nginx 内部验证失败时也不会把错误当成成功。

仅修改导航链接或只改 SameSite 都不完整：用户仍可能误开登录页或恢复旧登录标签页。会话保护需要部署在所有用户实际经过的入口，不能让用户绕过 nginx 直连后端。

### 15.7 验证与排障

先区分**未登录路径检查**与**已登录会话检查**。没有 cookie 的 curl 最终获得 `200`，通常只代表成功打开登录表单；手动添加 Cookie 的 curl 也不模拟浏览器的 SameSite、Path 匹配和 cookie 覆盖行为。

服务端基础检查：

```bash
cd /opt/file-repository
docker compose ps
docker compose exec web nginx -t

# 服务端解析出的实际时长（需要对应启动日志仍被保留）
docker logs sftpgo 2>&1 | grep "token duration" | tail -1
# 示例包含：cookie token duration 12h0m0s, cookie refresh threshold 6h0m0s

# 检查登录页下发 cookie 的属性，但不输出完整凭证
curl -sS -D - -o /dev/null http://192.0.2.20:19080/web/client/login \
  | awk 'tolower($0) ~ /^set-cookie:/ {sub(/=[^;]*/, "=<REDACTED>"); print}'

# 内部验证端点不得允许外部直接调用
curl -sS -o /dev/null -w '%{http_code}\n' \
  http://192.0.2.20:19080/_sftpgo_session_check
# 预期：404
```

注意：GET 登录页下发的是 **WebLogin cookie**，不是登录成功后的 WebClient 会话 cookie。在 `2.7.1` 中，该登录表单 cookie 使用 `csrfTokenDuration`，默认为 4 小时，`cookie_lifetime` 更大时随之增大。不能用它的 `Max-Age` 直接推断所有配置下的已登录会话时长。

浏览器完整回归步骤：

1. 普通用户正常登录，确认进入 `/web/client/files`；在开发者工具 Application → Cookies 中查看 `jwt` 的 Path、SameSite、Expires。
2. 新开标签页访问 `/web/client/login`：应被转回文件页，而不是显示登录表单或覆盖会话 cookie。
3. 从另一个站点的导航页点击文件仓库卡片：应直接进入文件页。
4. 关闭浏览器并重开，在 cookie 未过期、未清除站点数据的前提下重复第 2、3 步，应仍能进入。
5. 主动退出登录后重访入口：应正常显示登录表单，不得出现跳转循环或无需认证访问文件的情况。
6. 用测试文件验证上传、下载和删除；另测超过 1 MB 的文件，避免遗漏 nginx 默认请求体上限等反代问题。
7. 检查 SFTPGo 日志中的客户端 IP 应为真实客户端，而不是 nginx 容器 IP；确认 SFTP 端口仍能正常使用。

这次故障的自动化回归使用 Chromium，覆盖了重新打开登录页、跨站点击导航卡片、关闭并重启浏览器、未登录 / 伪造 cookie 不放行，以及退出后旧会话失效。修复前“重开登录页再点导航卡片”连续失败，修复后通过，随后由实际 Edge 用户确认恢复正常。上传下载应作为部署验收另行测试，不能由会话测试通过来推断。

排障时可以临时记录路径、状态码、重定向目标及 cookie 是否存在，但不要记录完整 Cookie、Authorization、CSRF token 或登录正文。JWT 相当于登录凭证，不要发到公开解码网站、聊天记录或代码仓库；泄露后应注销对应会话，并删除临时副本。

### 15.8 哪些场景不受影响

本节的会话时长及 cookie 问题针对 Web 界面；REST API token 有单独的有效期配置。SFTP、FTP、WebDAV 等协议连接不使用这里的 Web 会话 cookie，不会因为 Web cookie 的 12 小时上限中断，但仍受各自的连接超时、权限和协议配置约束。

## 16. 常见问题

### 16.1 页面访问不了

```bash
docker compose -f /opt/file-repository/docker-compose.yml ps
docker logs --tail 200 sftpgo
docker logs --tail 200 sftpgo-web
ss -lntp | grep 19080
curl -I http://192.0.2.20:19080/web/admin
```

检查主机防火墙、客户端到服务器的路由和端口策略。

### 16.2 SFTP 无法连接

```bash
ss -lntp | grep 12022
ssh-keyscan -p 12022 192.0.2.20
sftp -vvv -P 12022 <用户名>@192.0.2.20
```

确认连接的是 `12022`，而不是 GitLab 使用的 `12222` 或主机 SSH 使用的 `22`。

### 16.3 用户看不到共享目录

检查：

- Folder 是否已创建。
- Group 是否引用该 Folder。
- Virtual path 是否设置为 `/shared` 等绝对路径。
- 用户是否加入了正确的 Primary 或 Secondary Group。
- 是否错误使用 Membership Group。
- 用户自身是否已在相同 Virtual path 配置了其他 Folder。
- 修改 Group 后用户是否重新登录。

### 16.4 共享目录只能查看不能上传

检查 Group 的 ACL/Permissions。只授予 `list` 和 `download` 时为只读，需要上传时还应授予 `upload`，根据使用场景增加 `overwrite`、`create_dirs`、`rename` 或 `delete`。

### 16.5 主机目录显示为本地用户名

容器以 UID/GID `1000:1000` 运行，宿主机执行 `ls` 时会显示 UID `1000` 对应的本地用户名。这是正常现象，不要随意改成 root 或开放为 `777`。

### 16.6 删除文件后磁盘空间没有明显下降

先检查是否仍有进程持有已删除文件，以及文件是否位于其他用户目录或备份中：

```bash
du -sh /opt/file-repository/data/*
lsof +L1
```

执行任何批量删除前，应先完成备份并确认路径范围。

### 16.7 登录后过一段时间就要重新登录

先看是否真的发生了过期，而不是一律增大 `cookie_lifetime`：

1. **空闲一段时间后要求登录**：cookie 的剩余有效期已耗尽，默认会话有效期只有 20 分钟。
2. **无论是否操作，满固定时长后要求登录**：例如 `cookie_lifetime=480` 无实际续期窗口，或会话达到 12 小时硬上限。
3. **换网络、连接 VPN 后突然要求登录**：默认 `token_validation=0` 要求客户端 IP 一致；使用反代时也要检查真实 IP 是否正确传递。
4. **SFTPGo 进程重启或容器重建后全部要求登录**：未固定 `signing_passphrase`，启动时签名密钥变化。单纯执行 `docker compose up -d` 不一定重建容器，不能把命令本身当成原因。
5. **刚登录几秒，再开登录页或恢复旧标签页就要求登录**：检查第 15.5 节的 WebLogin cookie 覆盖问题，延长时长无效。
6. **同站访问正常，但从另一个站点的导航卡片进入异常**：同时检查入口地址、SameSite 属性及浏览器实际重定向链，不能仅凭 `302` 或 `cookie=yes` 下结论。
7. **仅关闭浏览器后丢失会话**：检查隐私模式、关闭时清理站点数据、扩展行为，以及浏览器是否恢复了旧登录页。

配置取舍和不泄露凭证的排查步骤见第 15 节。

### 16.8 改了 nginx.conf，为什么行为没有变化

bind mount 文件内容更新，不等于 nginx 工作进程已加载新配置。只执行 `docker compose up -d web`，如果容器配置未变，已有进程可能仍在使用旧配置。

```bash
cd /opt/file-repository
docker compose exec web nginx -t && docker compose exec web nginx -s reload
```

同时确认请求经过业务 IP 的 nginx 入口，没有绕过反向代理直连 SFTPGo 后端。若入口重定向丢失 `19080` 端口，检查是否保留了 `absolute_redirect off`。

## 17. 监控建议

至少监控：

- SFTPGo 与 nginx 容器是否运行、是否频繁重启。
- Web 页面和 SFTP 端口是否可用；nginx 是否持续返回 `502` 或其他异常。
- 登录页保护是否仍有效，真实客户端 IP 是否正确记录。
- `/opt` 磁盘和 inode 使用率。
- 用户与共享 Folder 配额。
- 登录失败、暴力破解和异常来源 IP。
- 最近一次备份时间、大小和异机复制状态。
- HTTPS 证书到期时间。

快速巡检：

```bash
docker inspect sftpgo \
  --format 'status={{.State.Status}} restart={{.RestartCount}} policy={{.HostConfig.RestartPolicy.Name}}'
docker stats --no-stream sftpgo sftpgo-web
docker exec sftpgo-web nginx -t
df -h /opt
df -ih /opt
du -sh /opt/file-repository/config /opt/file-repository/data
curl -I http://192.0.2.20:19080/web/admin
```

## 18. 官方参考资料

以下链接对应 2.7 版开源（Community）文档：

- 文档首页：https://docs.sftpgo.com/
- WebAdmin 与 WebClient：https://docs.sftpgo.com/2.7/web-interfaces/
- Group：https://docs.sftpgo.com/2.7/groups/
- Virtual Folder：https://docs.sftpgo.com/2.7/virtual-folders/
- 全部配置项：https://docs.sftpgo.com/2.7/config-file/
- 环境变量：https://docs.sftpgo.com/2.7/env-vars/
- 源码与版本：https://github.com/drakkan/sftpgo
- SFTPGo 2.7.1 Release：https://github.com/drakkan/sftpgo/releases/tag/v2.7.1
- 2.7.1 Web 路由与登录页处理：[server.go](https://github.com/drakkan/sftpgo/blob/v2.7.1/internal/httpd/server.go)（`setupWebClientRoutes`、`handleClientWebLogin`、`renderClientLoginPage`、`checkCookieExpiration`）
- 2.7.1 cookie 创建与时长：[auth_utils.go](https://github.com/drakkan/sftpgo/blob/v2.7.1/internal/httpd/auth_utils.go)（`createCSRFToken`、`createLoginCookie`、`setCookie`、`updateTokensDuration`）
- nginx 会话验证子请求：[ngx_http_auth_request_module](https://nginx.org/en/docs/http/ngx_http_auth_request_module.html)
- nginx cookie 属性改写：[proxy_cookie_flags](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_cookie_flags)
- nginx 相对重定向：[absolute_redirect](https://nginx.org/en/docs/http/ngx_http_core_module.html#absolute_redirect)
- Docker 端口发布与防火墙：[Packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
