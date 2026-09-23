---
title: "使用 Docker Compose 部署与维护 GitLab CE"
date: 2026-07-15
---

> 文中的 `192.0.2.0/24` 为文档示例网段，部署时请替换为实际服务器地址。

## 1. 文档说明

本文档用于在 `192.0.2.20` 上通过 Docker Compose 部署和维护 GitLab CE，并将配置、日志和业务数据持久化到 `/opt/gitlab`。

示例部署基线如下：

| 项目 | 配置 |
| --- | --- |
| 服务器 | `192.0.2.20` |
| 部署方式 | Docker Compose |
| GitLab 版本 | GitLab CE `18.2.1-ce.0` |
| Web 地址 | `http://192.0.2.20:18080` |
| Git SSH 端口 | `12222` |
| 配置目录 | `/opt/gitlab/config` |
| 日志目录 | `/opt/gitlab/logs` |
| 数据目录 | `/opt/gitlab/data` |
| 容器名称 | `gitlab` |

> 生产环境不要使用 `latest` 镜像。应固定完整版本号，并按照 GitLab 官方升级路径逐级升级。

## 2. 部署架构

```text
开发机
  ├─ HTTP 18080 ──> 192.0.2.20:18080 ──> GitLab Web
  └─ SSH  12222 ──> 192.0.2.20:12222 ──> GitLab SSH 22

192.0.2.20
  ├─ /opt/gitlab/config ──> /etc/gitlab
  ├─ /opt/gitlab/logs  ──> /var/log/gitlab
  └─ /opt/gitlab/data  ──> /var/opt/gitlab
```

容器被删除或重新创建时，只要 `/opt/gitlab` 未丢失，GitLab 的仓库、数据库、上传文件和配置仍然保留。

## 3. 部署前检查

### 3.1 检查主机资源

```bash
uname -m
df -h /opt
free -h
timedatectl status
```

确保：

- `/opt` 有足够空间，并预留备份和升级所需的额外空间。
- 系统时间同步正常。
- `18080` 和 `12222` 未被其他程序占用。
- Docker 和 Docker Compose 已安装。

```bash
docker version
docker compose version
ss -lntp | grep -E ':18080|:12222'
```

### 3.2 启用 Docker 开机自启

```bash
sudo systemctl enable --now docker
sudo systemctl is-enabled docker
sudo systemctl is-active docker
```

### 3.3 创建持久化目录

```bash
sudo mkdir -p /opt/gitlab/config
sudo mkdir -p /opt/gitlab/logs
sudo mkdir -p /opt/gitlab/data
sudo chown -R root:root /opt/gitlab
```

不要提前递归修改三个数据目录内部的权限。GitLab 容器会为各组件设置所需的 UID、GID 和文件权限。

## 4. 编写 Docker Compose 配置

在 `/opt/gitlab/docker-compose.yml` 写入以下配置：

```yaml
services:
  gitlab:
    image: gitlab/gitlab-ce:18.2.1-ce.0
    container_name: gitlab
    hostname: 192.0.2.20
    restart: always
    shm_size: 256m
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'http://192.0.2.20:18080'
        gitlab_rails['gitlab_shell_ssh_port'] = 12222
        letsencrypt['enable'] = false
    ports:
      - "192.0.2.20:18080:18080"
      - "192.0.2.20:12222:22"
    volumes:
      - /opt/gitlab/config:/etc/gitlab:Z
      - /opt/gitlab/logs:/var/log/gitlab:Z
      - /opt/gitlab/data:/var/opt/gitlab:Z
```

说明：

- 使用固定镜像版本，避免一次普通重启意外升级 GitLab。
- `restart: always` 配合 Docker 服务自启，可在服务器重启后自动恢复 GitLab。
- 端口绑定到服务器业务 IP，避免无意监听其他网卡。
- `:Z` 用于 SELinux 主机的卷标签处理。
- 当前示例为 HTTP。未正确配置证书前，不要只添加 `18443:443` 并认为 HTTPS 已启用。

## 5. 启动 GitLab

### 5.1 校验并启动

```bash
cd /opt/gitlab
sudo docker compose config
sudo docker compose pull
sudo docker compose up -d
sudo docker compose ps
```

首次启动通常需要数分钟。查看初始化过程：

```bash
sudo docker logs -f --tail 200 gitlab
```

日志显示服务就绪后，按 `Ctrl+C` 退出日志查看，不会停止容器。

### 5.2 验证服务

```bash
sudo docker inspect gitlab --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}'
sudo docker exec gitlab gitlab-ctl status
curl -I http://192.0.2.20:18080/users/sign_in
```

浏览器访问：

```text
http://192.0.2.20:18080
```

### 5.3 获取首次登录密码

全新安装时可执行：

```bash
sudo docker exec gitlab grep 'Password:' /etc/gitlab/initial_root_password
```

用户名为 `root`。首次登录后应立即修改密码。该初始密码文件会被 GitLab 自动清理，不应把密码写进部署文档、脚本或代码仓库。

## 6. Git 仓库地址

HTTP 地址：

```text
http://192.0.2.20:18080/<命名空间>/<仓库名>.git
```

SSH 地址：

```text
ssh://git@192.0.2.20:12222/<命名空间>/<仓库名>.git
```

示例：

```bash
git clone http://192.0.2.20:18080/example-group/demo-project.git
git clone ssh://git@192.0.2.20:12222/example-group/demo-project.git
```

建议开发人员配置 SSH 公钥，并优先使用 SSH 拉取和推送代码。

## 7. 日常启停与状态检查

```bash
cd /opt/gitlab

# 查看状态
sudo docker compose ps

# 查看日志
sudo docker compose logs --tail 200 gitlab

# 重启
sudo docker compose restart gitlab

# 停止
sudo docker compose stop gitlab

# 启动
sudo docker compose start gitlab

# 按 Compose 配置重新创建容器
sudo docker compose up -d
```

不要使用 `docker compose down -v`。虽然当前使用的是主机绑定目录，但生产环境不应养成删除卷的操作习惯。

执行完整健康检查：

```bash
sudo docker exec -t gitlab gitlab-rake gitlab:check SANITIZE=true
sudo docker exec -t gitlab gitlab-rake gitlab:doctor:secrets
```

## 8. 开机自动恢复验证

检查 Docker 和容器重启策略：

```bash
sudo systemctl is-enabled docker
sudo docker inspect gitlab --format '{{.HostConfig.RestartPolicy.Name}}'
```

预期结果分别为 `enabled` 和 `always`。

服务器维护重启后执行：

```bash
sudo docker ps --filter name=gitlab
sudo docker exec gitlab gitlab-ctl status
curl -I http://192.0.2.20:18080/users/sign_in
```

同一台主机上不得保留另一个使用相同端口、且带自动重启策略的旧 GitLab 容器。

## 9. 数据备份

### 9.1 备份范围

GitLab 应至少备份两部分：

1. GitLab 业务备份：数据库、Git 仓库、上传文件、制品等。
2. 配置与密钥：`gitlab.rb`、`gitlab-secrets.json` 和 `docker-compose.yml`。

仅复制仓库目录不是完整备份；仅执行 `gitlab-backup create` 也不会完整备份配置和密钥。

### 9.2 创建业务备份

```bash
sudo docker exec -t gitlab gitlab-backup create
sudo ls -lh /opt/gitlab/data/backups
```

备份文件默认保存在：

```text
/opt/gitlab/data/backups/
```

### 9.3 备份配置和密钥

建议将配置备份到独立目录后，再复制到另一台服务器或对象存储：

```bash
sudo mkdir -p /opt/gitlab/config-backups
sudo tar -C /opt/gitlab -czf /opt/gitlab/config-backups/gitlab-config-$(date +%F-%H%M%S).tar.gz \
  config/gitlab.rb \
  config/gitlab-secrets.json \
  docker-compose.yml
```

`gitlab-secrets.json` 可以解密数据库中的敏感数据，备份文件必须限制访问权限：

```bash
sudo chmod 600 /opt/gitlab/config-backups/*.tar.gz
```

### 9.4 备份原则

- 至少保留一份异机或离线备份，不能只放在 `/opt/gitlab` 同一块磁盘上。
- 定期执行恢复演练，仅看到备份文件生成并不代表一定可恢复。
- 记录备份对应的 GitLab 完整版本和 CE/EE 类型。
- 根据磁盘容量制定保留周期，例如每日备份保留 7 天、每周备份保留 4 周。
- 自动清理前先确认文件名匹配范围，避免误删其他文件。

## 10. 数据恢复

恢复目标必须安装与备份一致的 GitLab 完整版本和版本类型。例如，`18.2.1-ce.0` 的备份应先恢复到 `18.2.1-ce.0`。

以下以占位备份文件为例：

```text
<BACKUP_ID>_gitlab_backup.tar
```

恢复时使用的 BACKUP ID 为：

```text
<BACKUP_ID>
```

恢复步骤：

```bash
# 1. 将备份文件放入备份目录
sudo cp <备份文件> /opt/gitlab/data/backups/
sudo docker exec gitlab chown git:git /var/opt/gitlab/backups/<备份文件名>

# 2. 确保 GitLab 容器正在运行，然后停止写入服务
sudo docker exec gitlab gitlab-ctl stop puma
sudo docker exec gitlab gitlab-ctl stop sidekiq

# 3. 执行恢复，不要带 _gitlab_backup.tar 后缀
sudo docker exec -it gitlab gitlab-backup restore BACKUP=<BACKUP_ID>

# 4. 恢复匹配的 gitlab.rb 和 gitlab-secrets.json 后重新配置
sudo docker exec gitlab gitlab-ctl reconfigure
sudo docker restart gitlab

# 5. 验证
sudo docker exec -t gitlab gitlab-rake gitlab:check SANITIZE=true
sudo docker exec -t gitlab gitlab-rake gitlab:doctor:secrets
```

恢复会覆盖目标 GitLab 中的现有数据，应在维护窗口执行，并在操作前再次备份目标环境。

## 11. GitLab 升级

本文使用 `18.2.1` 演示固定版本部署。该版本已不是长期维护版本，实际使用时应选择受维护版本，并按 required upgrade stops 逐级升级。

升级原则：

- 升级前完成业务备份、配置备份和恢复可用性检查。
- 阅读 GitLab 官方升级路径和目标版本说明。
- 先升级当前大版本的补丁版本，再按 required upgrade stops 逐级升级。
- 每一级升级后确认服务健康、后台迁移完成，再进入下一级。
- 始终修改 Compose 中的固定版本号，不使用 `latest`。

一次版本升级的基本操作：

```bash
cd /opt/gitlab

# 先备份
sudo docker exec -t gitlab gitlab-backup create

# 修改 docker-compose.yml 中的 image 版本后校验并升级
sudo docker compose config
sudo docker compose pull gitlab
sudo docker compose up -d gitlab

# 观察升级过程
sudo docker compose logs -f --tail 200 gitlab
```

升级完成后检查：

```bash
sudo docker exec gitlab gitlab-rake gitlab:env:info
sudo docker exec -t gitlab gitlab-rake gitlab:check SANITIZE=true
```

升级路线必须在实际操作当天重新查看官方文档，不能只依赖本文档中记录的旧路线。

## 12. HTTPS 配置建议

示例中的 `http://192.0.2.20:18080` 为明文传输，登录密码、令牌和代码都不适合通过不可信网络传输。

生产环境建议：

1. 为 GitLab 分配稳定域名，例如 `gitlab.example.internal`。
2. 使用 Nginx、HAProxy 或负载均衡器终止 TLS。
3. 使用受客户端信任的证书。
4. 将 GitLab 的 `external_url` 改为正式的 HTTPS 地址。
5. 验证 Git clone、SSH、WebHook、Runner 注册和回调地址。

如果仅在内网使用，也应使用内部 CA 证书，并将 CA 根证书安装到开发机和 Runner。不要通过关闭证书校验来长期绕过问题。

## 13. 安全加固清单

- 禁止开放注册，或保留管理员审批。
- 管理员账号启用双因素认证，并减少不必要的管理员数量。
- 使用项目访问令牌、部署令牌或个人访问令牌，不在脚本中保存账号密码。
- 仅向受信任网段开放 `18080` 和 `12222`。
- 主机 SSH 禁止 root 密码登录，优先使用密钥认证。
- 定期更新 GitLab、Docker 和主机安全补丁。
- 配置 HTTPS，不在非可信网络使用 HTTP。
- 备份文件异机保存并加密，严格保护 `gitlab-secrets.json`。
- GitLab Runner 使用最小权限；非必要时不要挂载 `/var/run/docker.sock`。
- Kubernetes Runner 不应长期使用不受限制的 `ClusterRole`。
- 设置磁盘、内存、容器状态、HTTP 健康和备份结果告警。

## 14. GitLab Runner（可选）

GitLab 本身不需要 Runner 才能提供代码托管。只有执行 CI/CD Job 时才需要部署 Runner。

若部署 Runner：

- 优先创建专用 Runner，不要与 GitLab 容器共用数据目录。
- 使用 GitLab 提供的 Runner authentication token 注册，不使用已废弃的注册方式。
- 根据项目选择 Docker、Shell 或 Kubernetes executor。
- 对不可信项目禁用 privileged 模式。
- 为 Runner 设置 tag，并限制其只能执行匹配的项目。

如果不希望项目自动启动默认流水线，可在 GitLab 管理后台关闭全局 Auto DevOps，或在项目的 `Settings > CI/CD > Auto DevOps` 中关闭。项目中存在 `.gitlab-ci.yml` 时，推送仍会按照该文件创建流水线，需要删除、改名或通过 `workflow: rules` 控制。

## 15. 常见问题

### 15.1 启动后访问返回 502

GitLab 初始化期间可能暂时返回 502。先确认容器没有不断重启，再查看日志：

```bash
sudo docker ps -a --filter name=gitlab
sudo docker logs --tail 300 gitlab
sudo docker exec gitlab gitlab-ctl status
```

若 Puma、Gitaly 或 PostgreSQL 未运行，根据对应日志排查，不要反复删除容器和数据目录。

### 15.2 浏览器能访问，但 git clone 返回 502

先检查客户端是否配置了 HTTP 代理：

```bash
git config --global --get http.proxy
git config --global --get https.proxy
env | grep -i proxy
```

内网地址应加入代理绕过列表，例如：

```bash
export NO_PROXY=192.0.2.20,localhost,127.0.0.1
export no_proxy="$NO_PROXY"
```

也可仅对该地址禁用 Git 代理：

```bash
git config --global http.http://192.0.2.20:18080.proxy ""
```

### 15.3 容器启动后提示权限错误

检查挂载和 SELinux 标签：

```bash
sudo docker inspect gitlab --format '{{json .Mounts}}'
getenforce
sudo ls -ldZ /opt/gitlab /opt/gitlab/{config,logs,data}
```

不要直接对 `/opt/gitlab` 执行宽泛的 `chmod -R 777`。

### 15.4 端口被占用

```bash
sudo ss -lntp | grep -E ':18080|:12222'
sudo docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

停止冲突服务或修改 Compose 端口后，还要同步修改 `external_url` 或 `gitlab_shell_ssh_port`。

## 16. 监控建议

至少监控以下指标：

- GitLab 页面和健康端点是否可访问。
- 容器是否为 running/healthy，是否频繁重启。
- `/opt` 磁盘使用率和 inode 使用率。
- 主机内存、CPU 和负载。
- PostgreSQL、Redis、Gitaly、Puma、Sidekiq 状态。
- 最近一次备份时间、备份大小和异机复制结果。
- SSL 证书到期时间。

快速巡检命令：

```bash
df -h /opt
df -ih /opt
sudo docker stats --no-stream gitlab
sudo docker exec gitlab gitlab-ctl status
sudo du -sh /opt/gitlab/config /opt/gitlab/logs /opt/gitlab/data
sudo ls -lht /opt/gitlab/data/backups | head
```

## 17. 变更与回滚要求

任何升级、迁移、端口调整或 HTTPS 改造前，应记录：

- 操作时间和负责人。
- 变更前后的 GitLab 镜像版本。
- 变更前的容器配置和端口映射。
- 最新业务备份、配置备份及其异机位置。
- 验证项目和验收结果。
- 回滚版本、回滚镜像和恢复步骤。

回滚不能只把镜像标签改回旧版本。GitLab 数据库一旦完成不兼容迁移，通常需要使用升级前备份恢复到同版本实例。

## 18. 官方参考资料

- Docker 安装：https://docs.gitlab.com/install/docker/installation/
- Docker 备份：https://docs.gitlab.com/install/docker/backup/
- 备份恢复：https://docs.gitlab.com/administration/backup_restore/restore_gitlab/
- 升级路径：https://docs.gitlab.com/update/upgrade_paths/
- GitLab 维护策略：https://docs.gitlab.com/policy/maintenance/
