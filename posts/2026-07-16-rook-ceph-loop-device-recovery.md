---
title: "Rook-Ceph 使用 Loop 设备的故障排查与开机恢复"
date: 2026-07-16
---

这篇笔记记录一个 Rook-Ceph 集群因宿主机重启丢失 loop 映射，导致 OSD、CSI、PVC 和业务 Pod 连锁故障的排查与处理过程，并给出支持后续增加 loop 设备的动态开机恢复方案。

文中的节点名和集群规模经过泛化，不包含真实业务地址。所有命令默认使用 root 用户执行。

## 为什么使用 Loop 设备

Ceph BlueStore 通常直接使用裸磁盘或裸块设备。当前环境中的服务器只有一块容量较大的系统盘，磁盘已经全部划入 LVM，并分别挂载到 `/`、`/var` 和 `/home`，没有可以直接交给 Rook-Ceph 的空闲裸盘。

为了在不增加磁盘、不重新划分现有系统盘的情况下部署 Ceph，当时采用了文件模拟块设备的方案：

```text
/var/ceph/rook.osd.1 -> /dev/loop1
/var/ceph/rook.osd.2 -> /dev/loop2
/var/ceph/rook.osd.3 -> /dev/loop3
```

Rook-Ceph 清单中再将这些 loop 设备声明为 OSD 设备：

```yaml
storage:
  useAllNodes: false
  useAllDevices: false
  devices:
    - name: /dev/loop1
    - name: /dev/loop2
    - name: /dev/loop3
```

这种方案可以让 Ceph BlueStore 把普通文件当作块设备使用，适合实验、测试或没有独立数据盘的受限环境，但它不等同于真正的独立磁盘。

## Loop 方案的限制

Loop OSD 主要存在以下问题：

- `losetup` 映射默认不会跨重启保存。
- OSD 文件、Kubernetes 数据和系统服务共同使用 `/var`，存在 I/O 竞争。
- 同一节点的多个 loop OSD 最终仍落在同一个底层磁盘或逻辑卷上。
- 增加 OSD 时需要同时增加文件、loop 映射和 Rook 设备配置。
- 宿主文件系统损坏会同时影响该节点上的全部 loop OSD。
- 如果初始化脚本包含 `dd`、`truncate` 或 `fallocate`，重复执行可能覆盖已有 OSD 数据。

多副本可以提供节点级冗余，但无法把同一节点上的多个 loop 文件变成真正独立的物理磁盘。

## 故障现象

宿主机重启后，Kubernetes 节点仍然显示 `Ready`，但 Rook-Ceph 和业务 Pod 出现大量告警。

OSD Pod 的 `activate` 初始化容器不断重启：

```text
lsblk: /dev/loop1: not a block device
ceph-volume raw list returned {}
no disk found with OSD ID 0
```

Ceph 状态显示 OSD down，PG inactive 或 unknown：

```text
HEALTH_WARN
Reduced data availability: pgs inactive
```

CSI 挂载开始报错：

```text
rpc error: code = Aborted desc = an operation with the given Volume ID already exists
```

依赖 Ceph PVC 的数据库、Redis 和虚拟机 Pod 出现 `FailedMount`，后端服务因为依赖不可用进入 `CrashLoopBackOff`。

这些现象看起来分散，实际故障链路是：

```text
宿主机重启
  -> loop 映射丢失
  -> Ceph OSD 无法读取 BlueStore
  -> PG 不可用
  -> CSI 无法挂载 RBD
  -> 数据库、Redis、虚拟机卷不可用
  -> 上层服务启动失败
```

## 确认故障根因

### 检查 Loop 映射

```bash
losetup -a
ls -l /dev/loop-control /dev/loop* 2>&1
lsmod | grep '^loop'
```

故障时 `losetup -a` 没有输出，`/dev/loop1` 等设备节点也不存在。

### 检查 OSD 文件

不要修改文件，先确认文件名、大小、属主和权限：

```bash
stat -c '%n %s %U:%G %a' /var/ceph/rook.osd.*
```

本次故障中 OSD 文件仍然存在且大小正常，说明数据文件没有丢失，只是 loop 映射没有恢复。

### 确认 Rook 使用的设备

```bash
kubectl get cephcluster -n rook-ceph -o yaml

kubectl get deployment -n rook-ceph -l app=rook-ceph-osd \
  -o custom-columns='NAME:.metadata.name,NODE:.spec.template.spec.nodeSelector.kubernetes\.io/hostname,DEVICE:.spec.template.spec.containers[0].env[?(@.name=="ROOK_BLOCK_PATH")].value'
```

必须确认每个 OSD 原来使用的设备编号，不能凭猜测交换 OSD 文件和 loop 设备。

## 紧急恢复

### 1. 恢复 Loop 模块和设备

先加载 loop 模块：

```bash
modprobe loop max_loop=64
udevadm settle
```

如果模块已经以动态模式加载，但没有生成所需设备，并且 `losetup -a` 确认当前没有任何正在使用的 loop 映射，可以重新加载模块：

```bash
modprobe -r loop
modprobe loop max_loop=64
udevadm settle
```

只有在确认没有 loop 设备正在使用时才能卸载模块。

### 2. 按原编号恢复映射

以下只是示例，必须按实际环境确认对应关系：

```bash
losetup /dev/loop1 /var/ceph/rook.osd.1
losetup /dev/loop2 /var/ceph/rook.osd.2
losetup /dev/loop3 /var/ceph/rook.osd.3
```

验证 BlueStore 标识：

```bash
losetup -a
lsblk -o NAME,MAJ:MIN,SIZE,TYPE,FSTYPE /dev/loop1 /dev/loop2 /dev/loop3
```

预期 `FSTYPE` 为：

```text
ceph_bluestore
```

### 3. 重建 OSD Pod

映射正确后，让 Deployment 创建新的 OSD Pod：

```bash
kubectl delete pod -n rook-ceph -l app=rook-ceph-osd

kubectl wait -n rook-ceph \
  --for=condition=Ready pod \
  -l app=rook-ceph-osd \
  --timeout=180s
```

检查 Ceph：

```bash
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph status
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd tree
```

必须先确认 OSD 全部 `up/in`，PG 恢复为 `active+clean`，再处理 CSI 和业务 Pod。

### 4. 刷新 CSI

Ceph 恢复后，如果 CSI 仍然重复报告 `operation ... already exists`，可以只重建故障节点上的 RBD CSI Pod：

```bash
kubectl get pod -n rook-ceph \
  -l app=csi-rbdplugin \
  -o wide

kubectl delete pod -n rook-ceph <故障节点上的-csi-rbdplugin-pod>
```

等待 DaemonSet 创建的新 Pod 进入 `Running`。不要在 Ceph 仍不可用时反复重启 CSI。

### 5. 恢复业务 Pod

数据库和 Redis 通常会在存储恢复后自动挂载。如果上层服务仍停留在旧的 CrashLoop 状态，可以删除对应 Pod，让 Deployment 重建：

```bash
kubectl delete pod -n <namespace> -l <backend-label>
```

最后检查所有命名空间：

```bash
kubectl get pod -A -o wide
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp
```

## 配置动态开机映射

固定写死 `loop1`、`loop2`、`loop3` 可以解决当前问题，但以后增加 `rook.osd.4` 时还要修改脚本。这里改为按照文件名动态映射。

映射规则为：

```text
/var/ceph/rook.osd.N -> /dev/loopN
```

脚本不会创建、扩容或覆盖 OSD 文件，只负责校验并恢复映射。

### 动态映射脚本

安装路径：

```text
/usr/local/sbin/attach-rook-ceph-loops.sh
```

内容如下：

```bash
#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

readonly BACKING_DIR=/var/ceph
readonly FILE_PREFIX=rook.osd.
readonly MAX_LOOP_DEVICES=64
readonly MIN_BACKING_SIZE=$((1024 * 1024 * 1024))

modprobe loop max_loop="${MAX_LOOP_DEVICES}"
udevadm settle

backing_files=("${BACKING_DIR}/${FILE_PREFIX}"*)
if (( ${#backing_files[@]} == 0 )); then
  echo "No Ceph loop backing files found in ${BACKING_DIR}" >&2
  exit 1
fi

for backing_file in "${backing_files[@]}"; do
  basename="${backing_file##*/}"
  if [[ ! "${basename}" =~ ^rook\.osd\.([1-9][0-9]*)$ ]]; then
    echo "Ignoring unrelated file: ${backing_file}" >&2
    continue
  fi

  number="${BASH_REMATCH[1]}"
  if (( number >= MAX_LOOP_DEVICES )); then
    echo "Loop number ${number} exceeds configured limit $((MAX_LOOP_DEVICES - 1))" >&2
    exit 1
  fi
  if [[ ! -f "${backing_file}" || -L "${backing_file}" ]]; then
    echo "Backing path must be a regular, non-symlink file: ${backing_file}" >&2
    exit 1
  fi

  backing_size="$(stat -c %s "${backing_file}")"
  if (( backing_size < MIN_BACKING_SIZE )); then
    echo "Backing file is unexpectedly small: ${backing_file} (${backing_size} bytes)" >&2
    exit 1
  fi

  device="/dev/loop${number}"
  sys_device="/sys/block/loop${number}"
  if [[ ! -e "${sys_device}" ]]; then
    echo "Kernel loop device ${device} is unavailable; reboot once after raising max_loop" >&2
    exit 1
  fi
  if [[ ! -b "${device}" ]]; then
    mknod -m 0660 "${device}" b 7 "${number}"
    chown root:disk "${device}"
  fi

  expected_file="$(readlink -f "${backing_file}")"
  current_file="$(losetup -n -O BACK-FILE "${device}" 2>/dev/null || true)"
  if [[ -n "${current_file}" ]]; then
    current_file="$(readlink -f "${current_file}")"
    [[ "${current_file}" == "${expected_file}" ]] || {
      echo "${device} is already mapped to ${current_file}, expected ${expected_file}" >&2
      exit 1
    }
    continue
  fi

  existing_device="$(losetup -j "${expected_file}" | cut -d: -f1)"
  [[ -z "${existing_device}" ]] || {
    echo "${expected_file} is already mapped to ${existing_device}, expected ${device}" >&2
    exit 1
  }

  losetup "${device}" "${expected_file}"
done

losetup -a
```

设置权限：

```bash
chmod 0755 /usr/local/sbin/attach-rook-ceph-loops.sh
```

脚本包含以下保护：

- 只识别 `rook.osd.<正整数>`。
- 不接受软链接。
- OSD 文件必须至少为 1 GiB。
- 已正确映射时保持不变。
- 设备被其他文件占用时立即退出。
- 文件已经映射到其他编号时立即退出。
- 不自动创建或修改任何 OSD 文件。

### 配置 Loop 模块上限

创建 `/etc/modprobe.d/rook-ceph-loop.conf`：

```text
options loop max_loop=64
```

编号范围为 `loop1` 到 `loop63`。如果确实需要更多设备，应同时修改模块参数和脚本中的 `MAX_LOOP_DEVICES`，不能只改其中一处。

### 配置 systemd

创建 `/etc/systemd/system/rook-ceph-loop-devices.service`：

```ini
[Unit]
Description=Attach loop devices used by Rook Ceph OSDs
After=local-fs.target systemd-udevd.service
Before=kubelet.service
RequiresMountsFor=/var/ceph

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/attach-rook-ceph-loops.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

关键点：

- `RequiresMountsFor=/var/ceph` 确保 OSD 文件所在文件系统已经挂载。
- `Before=kubelet.service` 确保 Kubernetes 启动 OSD Pod 前完成 loop 映射。
- 没有配置 `ExecStop`，停止服务不会自动卸载正在使用的 OSD。
- `RemainAfterExit=yes` 让 oneshot 服务完成后保持 active 状态。

启用服务：

```bash
systemctl daemon-reload
systemctl enable --now rook-ceph-loop-devices.service
```

验证幂等性：

```bash
systemctl restart rook-ceph-loop-devices.service
systemctl is-enabled rook-ceph-loop-devices.service
systemctl is-active rook-ceph-loop-devices.service
systemctl show rook-ceph-loop-devices.service \
  -p Result \
  -p ExecMainStatus \
  -p Before \
  -p After
losetup -a
```

预期服务为 `enabled`、`active`、`Result=success`，多次执行不会改变已有正确映射。

## 后续增加 Loop OSD

动态脚本只解决开机映射，不负责创建 Ceph OSD。增加一个新的 loop OSD 时仍然需要：

1. 按规划创建新的 `/var/ceph/rook.osd.N` 文件。
2. 确保编号没有被使用，文件名与 `/dev/loopN` 严格对应。
3. 让动态脚本建立映射，确认 `losetup -a` 正确。
4. 在 Rook `CephCluster` 的 `storage.devices` 中增加 `/dev/loopN`。
5. 等待新 OSD 创建完成并检查 `ceph status`、`ceph osd tree`。

不要通过重新执行旧初始化脚本来增加 OSD。如果脚本中包含下面的命令，它会覆盖同名文件：

```bash
dd if=/dev/zero of=/var/ceph/rook.osd.1 ...
```

初始化命令只能针对确认不存在的新文件执行，绝不能作用于已经承载 BlueStore 数据的文件。

## 安全检查清单

处理 loop OSD 故障时，以下操作不能执行：

```text
ceph-volume zap
wipefs
删除 /var/ceph/rook.osd.*
对现有 OSD 文件执行 dd、truncate 或 fallocate
未确认数据均衡就删除 OSD、PV 或 PVC
```

推荐的处理顺序始终是：

```text
确认文件与设备关系
  -> 恢复 loop 映射
  -> 验证 ceph_bluestore
  -> 恢复 OSD 和 PG
  -> 刷新 CSI
  -> 恢复业务 Pod
```

## 最终状态

修复和配置完成后，应满足：

- 所有 loop 文件映射到相同编号的 loop 设备。
- 自动映射服务为 `enabled` 和 `active`。
- 服务启动顺序位于 kubelet 之前。
- 所有 OSD 为 `up/in`。
- 所有 PG 为 `active+clean`。
- CSI Pod 正常运行。
- 依赖 Ceph 的数据库、Redis、虚拟机和业务 Pod 恢复。

Loop OSD 仍然存在性能和故障域限制，但通过严格的命名规则、动态映射脚本和 systemd 启动顺序，可以避免宿主机重启后因映射丢失导致整个存储链路不可用。
