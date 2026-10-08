---
title: "使用 Helm 部署与维护 Headlamp"
date: 2026-07-15
---

> 文中的 `192.0.2.0/24` 为文档示例网段，部署时请替换为实际节点地址。

## 1. 文档说明

本文档用于在 Kubernetes 集群中通过 Helm 部署和维护 Headlamp，并通过控制节点 `192.0.2.10` 的 NodePort 对外提供访问。

Headlamp 是 Kubernetes SIG UI 维护的 Kubernetes Web 管理界面，可用于查看工作负载、节点、存储、日志和事件，并根据登录用户的 RBAC 权限管理集群资源。

## 2. 部署基线

| 项目 | 配置 |
| --- | --- |
| Kubernetes 版本 | `v1.31.0` |
| 集群架构 | ARM64 / `aarch64` |
| 控制节点 | `192.0.2.10` |
| 工作节点 | `192.0.2.11`、`192.0.2.12`、`192.0.2.13` |
| Helm 版本 | Helm 3 |
| Headlamp Chart | `0.43.0` |
| Headlamp 应用 | `0.43.0` |
| 命名空间 | `headlamp` |
| Helm Release | `headlamp` |
| Service 类型 | NodePort |
| NodePort | `32428` |
| 访问地址 | `http://192.0.2.10:32428` |

Headlamp Pod 不固定到某个节点，由 Kubernetes 调度器选择健康节点。NodePort 在集群节点上提供统一入口，因此 Pod 调度位置不会改变访问地址。

## 3. 部署架构

```text
浏览器
  │
  │ HTTP :32428
  ▼
192.0.2.10 NodePort
  │
  ▼
Headlamp Service
  │
  ▼
Headlamp Pod（由 Kubernetes 自动调度）
  │
  ▼
Kubernetes API Server
```

Headlamp 使用用户提交的 Bearer Token 调用 Kubernetes API。界面中可见和可执行的操作由该 Token 对应身份的 RBAC 权限决定。

## 4. 部署前检查

### 4.1 检查集群

在控制节点执行：

```bash
kubectl version
kubectl get nodes -o wide
kubectl get --raw='/readyz?verbose'
```

确认所有计划使用的节点处于 `Ready` 状态。

### 4.2 检查 Helm

```bash
helm version --short
helm list -A
```

### 4.3 检查端口

确认 NodePort `32428` 尚未被其他 Service 使用：

```bash
kubectl get service -A \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,NODEPORT:.spec.ports[*].nodePort' \
  | grep 32428
```

没有输出表示该端口未被 Kubernetes Service 占用。

### 4.4 检查旧 Dashboard

```bash
kubectl get namespace kubernetes-dashboard
kubectl get all -n kubernetes-dashboard
```

如果旧 Kubernetes Dashboard 已失效并确认不再使用，可在 Headlamp 验证完成后清理，不能在新界面可用前直接删除。

## 5. 配置 Helm 仓库

添加 Headlamp 官方 Helm 仓库：

```bash
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
helm repo update headlamp
```

检查指定版本：

```bash
helm show chart headlamp/headlamp --version 0.43.0
```

生产环境应固定 Chart 和镜像版本，不使用浮动版本或 `latest`。

## 6. Helm Values

部署配置文件为：

```text
headlamp-values.yaml
```

内容如下：

```yaml
replicaCount: 1

fullnameOverride: headlamp

image:
  registry: ghcr.io
  repository: headlamp-k8s/headlamp
  pullPolicy: IfNotPresent
  tag: v0.43.0

config:
  inCluster: true
  inClusterContextName: main
  sessionTTL: 28800
  enableHelm: false
  watchPlugins: false

clusterRoleBinding:
  create: false

service:
  type: NodePort
  port: 80
  nodePort: 32428

resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  runAsUser: 100
  runAsGroup: 101
  seccompProfile:
    type: RuntimeDefault
```

关键说明：

- Headlamp 使用官方固定版本镜像 `ghcr.io/headlamp-k8s/headlamp:v0.43.0`。
- `sessionTTL=28800` 将 Headlamp 内部会话限制为 8 小时。
- `clusterRoleBinding.create=false` 禁止给 Headlamp Pod 自身授予集群管理员权限。
- 管理员或只读权限通过独立的登录 ServiceAccount 提供。
- `readOnlyRootFilesystem=true`、非 root 用户和删除 Linux capabilities 用于减少容器权限。
- 未设置 `nodeSelector`，允许 Kubernetes 自动调度 Pod。

## 7. 部署 Headlamp

执行：

```bash
helm upgrade --install headlamp headlamp/headlamp \
  --version 0.43.0 \
  --namespace headlamp \
  --create-namespace \
  --values headlamp-values.yaml \
  --wait \
  --timeout 5m
```

检查 Helm Release：

```bash
helm list -n headlamp
helm status headlamp -n headlamp
```

## 8. 创建登录账号

### 8.1 管理员账号

管理员账号拥有整个集群的管理权限，只应提供给集群管理员：

```bash
kubectl create serviceaccount headlamp-admin \
  --namespace headlamp

kubectl create clusterrolebinding headlamp-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=headlamp:headlamp-admin
```

验证权限：

```bash
kubectl auth can-i '*' '*' \
  --as=system:serviceaccount:headlamp:headlamp-admin
```

预期返回：

```text
yes
```

### 8.2 只读账号

普通巡检人员建议使用只读账号：

```bash
kubectl create serviceaccount headlamp-viewer \
  --namespace headlamp

kubectl create clusterrolebinding headlamp-viewer \
  --clusterrole=view \
  --serviceaccount=headlamp:headlamp-viewer
```

内置 `view` ClusterRole 主要提供命名空间资源只读权限。如果还需要查看节点、持久卷等集群级资源，应创建经过审核的自定义 ClusterRole，不要直接升级为 `cluster-admin`。

## 9. 生成登录令牌

按需生成一个 1 小时有效的管理员令牌：

```bash
kubectl create token headlamp-admin \
  --namespace headlamp \
  --duration=1h
```

只读令牌：

```bash
kubectl create token headlamp-viewer \
  --namespace headlamp \
  --duration=8h
```

安全要求：

- 不要把 Token 写入部署文档、脚本、Git 仓库或聊天记录。
- 按需生成短期 Token，不创建永久 ServiceAccount Token Secret。
- 管理员离职或不再需要访问时，应删除对应 ServiceAccount 或 ClusterRoleBinding。
- Token 泄露后应立即删除 ServiceAccount 并重新创建。

## 10. 访问 Headlamp

浏览器访问：

```text
http://192.0.2.10:32428
```

选择 Token 登录，将上一节生成的 Bearer Token 粘贴到登录页面。

示例 NodePort 使用 HTTP，仅适合受信任的实验网络。HTTP 场景只应使用只读 Token；管理员 Token 应通过 HTTPS 页面使用，或临时通过 `kubectl port-forward` 在本机访问。生产环境应配置 HTTPS。

## 11. 部署验证

### 11.1 检查资源

```bash
kubectl get deployment,pod,service,serviceaccount \
  -n headlamp \
  -o wide
```

预期：

- Deployment 为 `1/1` Available。
- Pod 为 `1/1 Running`。
- Service 显示 `80:32428/TCP`。
- Pod 无持续重启。

### 11.2 检查页面

```bash
curl -I http://192.0.2.10:32428/
```

预期返回：

```text
HTTP/1.1 200 OK
```

### 11.3 检查日志

```bash
kubectl logs -n headlamp deployment/headlamp --tail=100
```

### 11.4 检查健康探针

```bash
kubectl describe pod -n headlamp \
  -l app.kubernetes.io/name=headlamp
```

确认 Readiness 和 Liveness Probe 没有连续失败。

### 11.5 功能验收

登录后至少验证：

1. 可以查看所有节点及其状态。
2. 可以切换命名空间。
3. 可以查看 Deployment、Pod 和 Service。
4. 可以查看 Pod 日志和事件。
5. 管理员账号能够执行授权范围内的操作。
6. 只读账号不显示或不能执行删除、修改操作。

## 12. 日常运维

### 12.1 查看状态

```bash
helm status headlamp -n headlamp
kubectl get all -n headlamp -o wide
```

### 12.2 查看日志

```bash
kubectl logs -n headlamp deployment/headlamp \
  --tail=200 \
  --follow
```

使用 `Ctrl+C` 退出日志查看，不会停止 Pod。

### 12.3 重启 Headlamp

```bash
kubectl rollout restart deployment/headlamp -n headlamp
kubectl rollout status deployment/headlamp -n headlamp
```

### 12.4 查看资源使用

```bash
kubectl top pod -n headlamp
kubectl top node
```

### 12.5 重新生成令牌

```bash
kubectl create token headlamp-admin \
  -n headlamp \
  --duration=1h
```

Headlamp 不需要保存登录 Token。令牌过期后重新生成即可。

## 13. HTTPS 建议

推荐通过现有 Ingress Controller 为 Headlamp 配置独立域名和 TLS：

```text
https://headlamp.example.com
```

实施原则：

- 使用受客户端信任的内部 CA 或公开 CA 证书。
- TLS 生效后将 Service 改回 `ClusterIP`，取消直接暴露 NodePort。
- 仅向受信任网段开放访问。
- 不要通过关闭证书校验长期绕过证书问题。
- 不要和其他不受信任应用共享同一个 URL 路径。

## 14. 升级

升级前：

```bash
helm repo update headlamp
helm search repo headlamp/headlamp --versions | head
helm get values headlamp -n headlamp
helm history headlamp -n headlamp
```

确认目标版本支持当前 Kubernetes 版本和 ARM64，然后同时修改：

```yaml
image:
  tag: v<目标版本>
```

执行升级：

```bash
helm upgrade headlamp headlamp/headlamp \
  --version <目标Chart版本> \
  --namespace headlamp \
  --values headlamp-values.yaml \
  --wait \
  --timeout 5m
```

升级后重新执行页面、Pod、日志和 RBAC 验证。

## 15. 回滚

查看历史版本：

```bash
helm history headlamp -n headlamp
```

回滚到指定 Revision：

```bash
helm rollback headlamp <REVISION> \
  --namespace headlamp \
  --wait \
  --timeout 5m
```

回滚后检查：

```bash
kubectl rollout status deployment/headlamp -n headlamp
curl -I http://192.0.2.10:32428/
```

## 16. 卸载

删除 Headlamp Helm Release：

```bash
helm uninstall headlamp -n headlamp
```

确认不再需要登录身份后删除 RBAC：

```bash
kubectl delete clusterrolebinding headlamp-admin \
  headlamp-viewer \
  --ignore-not-found
```

最后删除命名空间：

```bash
kubectl delete namespace headlamp
```

卸载 Headlamp 不会删除其他命名空间中的业务资源。

## 17. 常见问题

### 17.1 Pod 显示 ImagePullBackOff

```bash
kubectl describe pod -n headlamp \
  -l app.kubernetes.io/name=headlamp
```

检查：

- 镜像名称和固定版本是否正确。
- 节点是否能够访问镜像源。
- DNS、系统时间和 CA 证书是否正常。
- 是否存在失效的 `imagePullSecrets`。

标准镜像名称为：

```text
ghcr.io/headlamp-k8s/headlamp:v0.43.0
```

### 17.2 访问 NodePort 超时

```bash
kubectl get service headlamp -n headlamp
kubectl get endpointslice -n headlamp \
  -l kubernetes.io/service-name=headlamp
kubectl get pod -n headlamp -o wide
```

同时检查主机防火墙、网络 ACL 和 kube-proxy 状态。

### 17.3 页面返回 200，但登录失败

重新生成短期 Token：

```bash
kubectl create token headlamp-admin \
  -n headlamp \
  --duration=1h
```

验证 ServiceAccount 和绑定：

```bash
kubectl get serviceaccount headlamp-admin -n headlamp
kubectl get clusterrolebinding headlamp-admin -o yaml
```

### 17.4 登录后提示 Access Denied

Headlamp 根据 Token 的 RBAC 权限显示功能。检查具体权限：

```bash
kubectl auth can-i list pods --all-namespaces \
  --as=system:serviceaccount:headlamp:headlamp-viewer
```

不要为了消除单个权限错误直接授予 `cluster-admin`。应创建满足实际需求的最小权限 ClusterRole。

### 17.5 Pod 调度到其他节点

这是正常行为。示例没有配置 nodeSelector 或 nodeAffinity，调度器可以选择任意健康节点。访问地址仍然是：

```text
http://192.0.2.10:32428
```

### 17.6 Helm 安装提示资源已存在

检查旧部署：

```bash
helm list -A | grep headlamp
kubectl get all -A | grep -i headlamp
```

不要直接删除未知来源的资源。先确认资源所属 Helm Release、命名空间和是否仍被使用。

## 18. 安全清单

- Headlamp Pod 自身不绑定 `cluster-admin`。
- 管理员和只读用户使用不同的 ServiceAccount。
- 使用短期 Token，不保存永久 Token Secret。
- 不在文档、代码仓库和聊天记录中保存 Token。
- 管理入口仅对受信任网段开放。
- 尽快使用 HTTPS 替代 HTTP NodePort。
- 固定 Chart 和镜像版本。
- 定期查看 Headlamp 和 Kubernetes 安全公告。
- 按最小权限原则审计 ClusterRoleBinding。
- 离职或权限变更时及时删除相应绑定。

## 19. 官方资料

- Headlamp 官网：https://headlamp.dev/
- Headlamp 安装文档：https://headlamp.dev/docs/latest/installation/
- Headlamp GitHub：https://github.com/kubernetes-sigs/headlamp
- Helm Chart 仓库：https://kubernetes-sigs.github.io/headlamp/
- Kubernetes RBAC：https://kubernetes.io/docs/reference/access-authn-authz/rbac/
