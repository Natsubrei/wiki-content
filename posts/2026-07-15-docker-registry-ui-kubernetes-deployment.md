---
title: "在 Kubernetes 中部署 Docker Registry UI"
date: 2026-07-15
---

> 文中的 `192.0.2.0/24` 和 `example.com` 为文档示例值，部署时请替换为实际节点地址和域名。

## 1. 文档说明

本文档记录 `docker-registry-ui` 在现有 Kubernetes 集群中的部署、验证和日常维护方法。

该界面用于管理运行在 `192.0.2.10:5000` 上的 Docker Distribution Registry，包括查看仓库、查看标签、复制拉取命令和删除镜像标签。

## 2. 示例环境

### 2.1 Kubernetes 集群

| 项目 | 示例配置 |
| --- | --- |
| Kubernetes 节点 | `k8s-node-1` |
| 节点 IP | `192.0.2.10` |
| Kubernetes 版本 | `v1.31` |
| 节点架构 | `aarch64` |
| 容器运行时 | containerd `1.6.35` |
| UI 命名空间 | `registry-ui` |
| UI Deployment | `docker-registry-ui` |
| UI Service | `docker-registry-ui` |
| UI 访问端口 | NodePort `30081` |

### 2.2 Registry 服务

| 项目 | 示例配置 |
| --- | --- |
| Registry 容器 | `private-registry` |
| Registry 镜像 | `registry:2` |
| Registry 地址 | `https://registry.example.com:5000` |
| Registry 主机 | `192.0.2.10` |
| 认证方式 | Basic Auth / htpasswd |
| Registry 数据 | `/var/registry` |
| 认证文件 | `/opt/registry/auth/htpasswd` |
| TLS 文件 | `/opt/registry/certs` |
| 重启策略 | `always` |
| 删除 API | 已启用 |

在本示例中，`registry.example.com` 解析到 `192.0.2.10`，因此：

```text
localhost:5000
registry.example.com:5000
```

是同一个 Registry 服务，不是两个独立镜像仓库。UI 只需连接一次 `registry.example.com:5000`。

## 3. 部署架构

```text
用户浏览器
    │ HTTP :30081
    ▼
Kubernetes NodePort
    │
    ▼
docker-registry-ui Pod
    │ HTTPS + Basic Auth
    ▼
registry.example.com:5000
    │
    ▼
/var/registry
```

UI 使用自身的 Nginx 反向代理访问 Registry。浏览器不直接请求 Registry，因此不需要给 Registry 增加 CORS 配置，也可以避开带 Basic Auth 时的 OPTIONS 请求兼容问题。

## 4. 部署清单

完整 Kubernetes 清单文件为：

```text
registry-ui-k8s.yaml
```

核心配置如下：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: docker-registry-ui
  namespace: registry-ui
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: docker-registry-ui
  template:
    metadata:
      labels:
        app.kubernetes.io/name: docker-registry-ui
    spec:
      nodeSelector:
        kubernetes.io/hostname: k8s-node-1
      hostAliases:
        - ip: "192.0.2.10"
          hostnames:
            - registry.example.com
      containers:
        - name: docker-registry-ui
          image: joxit/docker-registry-ui:2.6.0
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: NGINX_LISTEN_PORT
              value: "8080"
            - name: NGINX_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE
              value: "1"
            - name: SINGLE_REGISTRY
              value: "true"
            - name: NGINX_PROXY_PASS_URL
              value: "https://registry.example.com:5000"
            - name: PULL_URL
              value: "registry.example.com:5000"
            - name: REGISTRY_SECURED
              value: "true"
            - name: DELETE_IMAGES
              value: "true"
            - name: SHOW_CONTENT_DIGEST
              value: "true"
```

Service 使用固定 NodePort：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: docker-registry-ui
  namespace: registry-ui
spec:
  type: NodePort
  ports:
    - port: 80
      targetPort: http
      nodePort: 30081
```

## 5. 关键配置说明

### 5.1 镜像版本

使用固定版本镜像：

```text
joxit/docker-registry-ui:2.6.0
```

版本固定为 `2.6.0`，避免使用 `latest` 导致重建 Pod 时自动升级。

### 5.2 域名解析

如果 `k8s-node-1` 可以解析 `registry.example.com`，但集群 CoreDNS 不能解析该域名，可以在 Deployment 中使用以下配置解决 Pod 内解析问题：

```yaml
hostAliases:
  - ip: "192.0.2.10"
    hostnames:
      - registry.example.com
```

不能简单把代理地址改成 `https://192.0.2.10:5000`，因为 Registry TLS 证书的 Subject Alternative Name 是 `registry.example.com`，使用 IP 会产生证书主机名不匹配。

### 5.3 非 root 运行

UI 容器使用 UID/GID `101` 运行，并监听容器内 `8080`：

```yaml
securityContext:
  allowPrivilegeEscalation: false
  runAsNonRoot: true
  runAsUser: 101
  runAsGroup: 101
  capabilities:
    drop:
      - ALL
```

### 5.4 Nginx worker 调优

`k8s-node-1` CPU 核数较多。若使用默认 `worker_processes auto`，容器会创建大量 Nginx worker。以下变量会根据容器 CPU 配额进行调优：

```yaml
NGINX_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE: "1"
```

示例将 UI CPU 上限设为 `500m`，调优后只创建一个 worker。

## 6. 部署操作

在能够访问集群的管理机上执行：

```bash
kubectl apply -f registry-ui-k8s.yaml
kubectl rollout status deployment/docker-registry-ui \
  -n registry-ui \
  --timeout=120s
```

如果通过 SSH 向集群提交当前目录中的清单：

```bash
ssh <SSH_USER>@192.0.2.10 'kubectl apply -f -' \
  < registry-ui-k8s.yaml
```

检查资源：

```bash
kubectl get deployment,pod,service -n registry-ui -o wide
```

预期 Pod 状态：

```text
READY   STATUS    RESTARTS
1/1     Running   0
```

## 7. 访问与登录

浏览器访问：

```text
http://192.0.2.10:30081
```

使用 Registry 的 Basic Auth 账号登录。账号保存在 Registry 的 `htpasswd` 文件中，部署文档不记录明文密码。

查看现有用户名：

```bash
cut -d: -f1 /opt/registry/auth/htpasswd
```

Registry 地址应始终写为：

```text
registry.example.com:5000
```

示例登录与拉取：

```bash
docker login registry.example.com:5000
docker pull registry.example.com:5000/<仓库>:<标签>
```

## 8. 部署验证

### 8.1 检查 UI 首页

```bash
curl -I http://192.0.2.10:30081/
```

预期返回：

```text
HTTP/1.1 200 OK
```

### 8.2 检查 Registry 代理

未提供认证信息时：

```bash
curl -I http://192.0.2.10:30081/v2/
```

预期返回 `401 Unauthorized`，并包含：

```text
Www-Authenticate: Basic realm="Registry Realm"
```

这里的 `401` 表示 UI 已成功连接 Registry，Registry 正在要求认证，不是部署失败。

提供正确账号后验证 catalog：

```bash
curl -u '<用户名>:<密码>' \
  http://192.0.2.10:30081/v2/_catalog
```

预期返回 HTTP `200` 和仓库列表。

### 8.3 查看 Pod 日志

```bash
kubectl logs -n registry-ui deployment/docker-registry-ui --tail=100
```

## 9. 日常维护

### 9.1 查看状态

```bash
kubectl get all -n registry-ui
kubectl describe pod -n registry-ui \
  -l app.kubernetes.io/name=docker-registry-ui
```

### 9.2 重启 UI

```bash
kubectl rollout restart deployment/docker-registry-ui -n registry-ui
kubectl rollout status deployment/docker-registry-ui -n registry-ui
```

### 9.3 更新 UI

先检查新版本是否支持 ARM64，再修改清单中的完整版本号：

```yaml
image: joxit/docker-registry-ui:<固定版本>
```

然后执行：

```bash
kubectl apply -f registry-ui-k8s.yaml
kubectl rollout status deployment/docker-registry-ui -n registry-ui
```

### 9.4 卸载 UI

```bash
kubectl delete -f registry-ui-k8s.yaml
```

卸载 UI 不会删除 `/var/registry` 中的镜像数据，也不会删除 Registry Docker 容器。

## 10. 账号密码维护

应使用高强度独立密码，并使用 `htpasswd` 的 bcrypt 模式更新密码：

```bash
htpasswd -B /opt/registry/auth/htpasswd <用户名>
docker restart private-registry
```

命令会交互式要求输入新密码，不要把密码直接写入 shell 历史。

修改后还需要同步更新：

- Kubernetes `imagePullSecrets`。
- GitLab CI/CD Variables。
- 开发机的 Docker 登录凭据。
- 其他使用该 Registry 的自动化脚本。

不要在部署文档、Git 仓库或 Kubernetes 明文 YAML 中保存 Registry 密码。

## 11. 镜像删除与磁盘清理

Registry 已设置：

```text
REGISTRY_STORAGE_DELETE_ENABLED=true
```

因此可以在 UI 中删除镜像标签。删除前应确认：

- 镜像不再被 Kubernetes Deployment、DaemonSet、Job 或虚拟机环境使用。
- 没有其他标签指向同一个 manifest digest。
- 重要镜像可以重新构建或已有备份。

UI 删除标签或 manifest 后，不一定立即释放 `/var/registry` 磁盘空间。真正回收未引用 blob 需要执行 Distribution Registry garbage collection。

垃圾回收应在维护窗口进行，并在执行前：

1. 备份 `/var/registry`。
2. 阻止新的镜像 push 和 delete。
3. 确认 Registry 配置和数据目录挂载正确。
4. 先使用 dry-run 或只读方式确认待删除内容。
5. 完成后重新验证登录、catalog、push 和 pull。

不要在 Registry 持续接收写入时直接运行可能删除 blob 的垃圾回收。

## 12. 安全说明

示例 UI 地址使用 HTTP：

```text
http://192.0.2.10:30081
```

Basic Auth 凭据从浏览器到 UI 的这段传输没有 TLS 保护。因此：

- 仅允许受信任内网访问 `30081`。
- 不要通过公网或不可信 Wi-Fi 登录。
- 建议通过现有 ingress-nginx 为 UI 配置 HTTPS。
- 配置 HTTPS 后限制或移除 HTTP NodePort。
- Registry 自身继续使用 `https://registry.example.com:5000`。

## 13. 常见问题

### 13.1 Pod 显示 ImagePullBackOff

检查事件：

```bash
kubectl describe pod -n registry-ui \
  -l app.kubernetes.io/name=docker-registry-ui
```

确认清单使用正确的镜像名称和固定版本：

```text
joxit/docker-registry-ui:2.6.0
```

### 13.2 日志显示 host not found in upstream

说明 Pod 无法解析 `registry.example.com`。检查：

```bash
kubectl get deployment docker-registry-ui -n registry-ui -o yaml
```

确认 `hostAliases` 仍指向：

```text
192.0.2.10 registry.example.com
```

### 13.3 页面弹出登录框后仍然返回 401

检查 Registry 本身：

```bash
curl --cacert /path/to/ca.crt -u '<用户名>:<密码>' \
  https://registry.example.com:5000/v2/_catalog
```

如果直接访问 Registry 也返回 `401`，应检查账号密码和 `htpasswd`，而不是重建 UI。

### 13.4 删除按钮失败

检查 Registry 容器环境：

```bash
docker inspect private-registry \
  --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep REGISTRY_STORAGE_DELETE_ENABLED
```

预期结果：

```text
REGISTRY_STORAGE_DELETE_ENABLED=true
```

### 13.5 删除后磁盘空间没有下降

这是 Registry 的正常行为。删除操作先移除引用，未引用 blob 需要经过垃圾回收才能释放磁盘空间。

## 14. 官方资料

- 项目主页：https://github.com/Joxit/docker-registry-ui
- Helm Chart：https://helm.joxit.dev/
- Distribution Registry：https://github.com/distribution/distribution
