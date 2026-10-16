---
title: "用 CDI 从 URL 导入系统盘：PVC、PV 与 Ceph 概念梳理"
date: 2026-10-15
---

## 第一部分：Kubernetes 侧的四个对象

### 问题 1：DV 是什么？和 PV 有什么区别？

**DV** = DataVolume。KubeVirt 周边的一个自定义资源，归 CDI 管。它描述的是一次「把数据导入一块 PVC」的作业。

**PV** = PersistentVolume。Kubernetes 核心资源，代表集群里真实存在的一块存储。

两者不在同一层，所以「区别」其实不太准确，更像是「一条链上的两个位置」：

```text
DV（数据导入流程）→ 创建并写入 PVC → PVC 再绑定 PV（真正的存储）
```

| | DV | PV |
| --- | --- | --- |
| 是什么 | 自定义资源，一段数据导入流程 | 核心资源，一块真实存储 |
| 作用域 | 命名空间 | 集群级 |
| 关心什么 | 数据从哪来、怎么导入 | 盘在哪、多大、什么 StorageClass |
| 生命周期 | 导入完成后通常只留下 PVC | 绑定、释放、回收，直到被删 |
| 谁实现 | CDI 控制器 | 存储驱动 / 管理员 |

判断标准很简单：**要一块空盘，用 PV/PVC；要「先把系统盘镜像导入再给虚拟机用」，才用 DV。**

而且虚拟机最终挂的还是 PVC，不是 DV。

### 问题 2：PVC 和 PV 是什么关系？为什么先创建 PVC？

PVC 是**用户要一块盘**，PV 是**集群里真有的那块盘**。绑定就是把两边对上。

```text
用户：我要 45Gi、ReadWriteOnce、ceph-block
        ↓ 创建 PVC（命名空间里）
控制面：找一块（或现做一块）匹配的存储
        ↓ bind
PV ←→ PVC  一对一锁死，Pod 只写 claimName
```

先创建 PVC，是因为 **PVC 表达的是需求**，而 PV 是满足需求的实物。应用不该知道底层是 Ceph 镜像、NFS 路径还是本地盘，就像 Pod 申请 CPU 时不挑具体哪颗核。

两条供给路径，用户侧都从 PVC 开始：

**动态供给（现在默认）**

```text
PVC 带 storageClassName
  → provisioner 按 class 现做一个 PV
  → 立刻 bind
```

这条路上你几乎看不到「先有 PV」。

**静态供给**

```text
管理员先建好 PV（手写 nfs、hostPath 等）
  → 用户再建 PVC
  → size / accessMode / class 都对得上才 bind
```

PV 可以先存在，但用户工作流仍然是创建 PVC。没有 PVC，PV 就是一块闲置的存储。

绑定之后：

- PVC 是命名空间对象，可以挂给 Pod 或虚拟机：`volumes.persistentVolumeClaim.claimName`
- PV 是集群对象，普通用户通常没权限直接用
- 一对一：一块 PV 同时只给一个 PVC
- 删 PVC 时 PV 按 `reclaimPolicy` 走：`Delete` 连盘删掉，`Retain` 留着等人处理

### 问题 3：StorageClass 是什么？

**StorageClass 描述如何创建 PV**：用哪个 provisioner、哪个存储池、删了怎么回收。

PVC 填 `storageClassName`，控制面就按这个 class 创建 PV。

```text
PVC
  storageClassName: ceph-block        # 用哪个 class
  resources.requests.storage: 45Gi    # 要多大
  accessModes: [ReadWriteOnce]
        ↓
StorageClass/ceph-block               # 集群里的 StorageClass 对象
  provisioner: rbd.csi.ceph.com
  parameters: pool=...
        ↓ 动态供给
PV                                    # 新做出来的实物
```

没有 StorageClass，或者 class 不做动态供给，就只能从已有的 PV 里配对。

### 问题 4：provisioner 是什么？

**provisioner 是 StorageClass 里指定由哪个驱动创建 PV 的字段。**

```text
PVC  storageClassName: ceph-block
        ↓
StorageClass
  provisioner: rbd.csi.ceph.com     # 由哪个驱动创建
        ↓
CSI 驱动创建一块 RBD → 登记成 PV → bind 回 PVC
```

class 和驱动是分开的。同一套 Ceph 可以有好几个 class（不同池、不同回收策略），但 provisioner 往往是同一个驱动。

### 问题 5：CSI 是什么？

**CSI** = Container Storage Interface，Kubernetes 对接存储的标准插件接口。

控制面和 kubelet 不内置 Ceph、NFS、云盘的实现，只负责调用 CSI。厂商提供驱动，驱动负责建盘、挂盘、扩容、克隆、删盘。

驱动通常拆成两个组件：

| 组件 | 运行位置 | 职责 |
| --- | --- | --- |
| Controller 插件 | 以 Deployment 常驻，一份即可 | 建盘、删盘、克隆、扩容——需要调存储后端 API 的操作 |
| Node 插件 | 以 DaemonSet 运行在每台节点 | 把盘挂到本机、格式化成文件系统——必须在本机做的操作 |

这两个在集群里都能看到：

```text
csi-rbdplugin-provisioner-6f8d9c4b7-x2k9p   5/5   Running   # Controller
csi-rbdplugin-j4ftq                         2/2   Running   # Node
```

整条链是：PVC 写 `ceph-block` → CSI Controller 在 Ceph 里创建卷 → 生成 PV。

### 问题 6：RBD 是什么？

**RBD** = RADOS Block Device，Ceph 里的块设备。池子里的一块虚拟磁盘，像一块远程硬盘。

CSI 创建的 PV，底层通常就是一个 RBD 镜像。虚拟机看到的是块设备，不直接访问 Ceph。

```text
PVC（K8s 的存储申请）
  → StorageClass/ceph-block
    → CSI 驱动
      → RBD 镜像（Ceph 池里的盘）
        → PV（K8s 对这块盘的登记）
```

### 问题 7：PVC 是命名空间级，为什么 PV 是集群级？

因为一边是**命名空间里的需求**，一边是**集群级的资源**。

**PVC 跟 Pod 一样**：某个账号在某个命名空间里要一块盘，权限、配额、删除都按命名空间隔离。别人看不见你的 PVC。

**PV 跟 Node 一样**：真正的容量在集群共享的存储池里（Ceph 集群、NFS、云盘）。盘不属于任何命名空间，管理员或存储驱动在全集群开、回收、配对。

如果 PV 也按命名空间划分，每个命名空间都得自备存储，动态供给和跨命名空间回收都做不成。

绑定就是跨这两层的对应关系：命名空间里的一个 PVC 对应集群里的一块 PV。应用只写 PVC 名，PV 名普通用户用不到。

### 问题 8：那块模板是 PVC 还是 PV？

**是 PVC。**

模板叫 `vm-template`，`dataSource.kind` 里写死的也是 `PersistentVolumeClaim`。

```text
模板 PVC  vm-template                 Bound → 模板 PV（基础镜像）
        ↑
        │ CSI clone（dataSource）
        │
新 PVC    vm-<account>-<code>
  storageClassName: ceph-block
  dataSource:
    name: vm-template
    kind: PersistentVolumeClaim
        ↓
新 PV     克隆出来的 45Gi RBD
```

克隆 API 的源是 PVC。模板 PVC 底下当然绑着一块模板 PV，但清单和应用都不引用那块 PV。

这也是为什么这个模板必须在每个要用它的命名空间里各存一份——后面问题 26 会说原因。

---

## 第二部分：Ceph 内部怎么放数据

到这里，问题变成：PV 底下那块 RBD，在 Ceph 里到底是怎么组织的。

### 问题 9：RADOS 是什么？

**RADOS** = Reliable Autonomic Distributed Object Store，Ceph 的底层对象存储。把数据切成对象，自动复制、自动分布到多台机器。

上面三种用法都建在它之上：

```text
RBD     块设备
CephFS  文件系统
RGW     S3 / Swift 对象接口
        ↓ 都建在
RADOS   分布式对象池
```

RBD 就是在 RADOS 上模拟出来的一块硬盘。应用看到块设备，RADOS 看到的是一堆对象。

### 问题 10：object 是什么概念？为什么这么设计？

**object 是 RADOS 真正存的东西**：一块有名字的字节。不是文件，不是整块硬盘，也不是编程语言里的对象。

RBD、CephFS、S3 都只是把「你看见的东西」切成这种 blob，再交给 RADOS。

要理解为什么这么设计，先看问题：45Gi 的虚拟机盘，怎么放到二十几块物理盘上，掉一块还能用？

两种极端都不行：

- **整盘当一份**：没法并行读写，恢复时要把整块重新复制一遍，热点集中在一块盘上。
- **每 4KB 当一份**：对象数和元数据量都不可接受。45Gi 会切成 1180 万个对象，光元数据就足以成为瓶颈。

所以拆三层，各管一件事：

```text
你看见的     45Gi 硬盘（RBD 镜像）
切小         object（通常 4MiB 一块）    ← 存什么
成组         PG（很多 object 一组）      ← 一起放置、一起恢复
放哪         CRUSH(PG) → 3 个 OSD        ← 计算位置，不查表
```

一次写入：

```text
虚拟机在偏移 8MiB 处写 4KB
  → 落在第 2 个 4MiB 条带
  → 对象名大约 rbd_data.<id>.0000000000000002
  → hash(名字) 进某个 PG
  → CRUSH 给出 OSD 1（主）、4、7
  → 三块盘都写下这 4KB
```

```text
RBD 镜像  [ obj0 | obj1 | obj2 | obj3 | ... ]
                    8MiB ↑
                       │
                    object（有名字的 4MiB 数据）
                       │ 很多 object 共享一个位置
                       PG
                       │ crush()
                  OSD1  OSD4  OSD7
```

那 4MiB 不是随便定的，它是**权衡出来的折中**：再大，丢一个对象要重传更多，恢复粒度变粗；再小，对象数变多，元数据开销上升。

可以实测：

```bash
rados -p vm-pool ls | grep rbd_data | head -5
# rbd_data.a1b2c3d4e5f6a7.0000000000002952
# rbd_data.b2c3d4e5f6a7b8.000000000000156d
# ...

rados -p vm-pool stat rbd_data.a1b2c3d4e5f6a7.0000000000002952
# size 4194304        ← 正好 4 MiB
```

多取几个都是 `4194304`。这个值来自 `rbd_default_order = 22`（2²² = 4194304）。

### 问题 11：PG 是什么？为什么有这个概念？

**PG** = Placement Group，放置组。

问题 10 里留了一个坑：object 已经很小了，为什么不让每个 object 自己选盘？

因为一个池里的 object 可以上亿。如果每个 object 独立算位置、独立复制、独立和副本协商状态、独立恢复，那么元数据量和节点间的握手次数都会成为瓶颈。

PG 的作用是**把很多 object 归为一组**，让放置、复制、状态协商、恢复都按组来做。

```text
object 名
  → hash
    → 落到某个 PG          # 这一步把亿级对象收成几千个组
      → CRUSH(PG, 规则)
        → OSD 1, 4, 7      # 这一组的所有 object 都在这三块盘
```

没有 PG：亿次选盘、亿次 peering。  
PG 太少：数据集中在少数 OSD 上，一块盘故障后要恢复的数据量极大。  
PG 太多：每个 OSD 要跟踪的组太多，内存和 peering 变重。

一句话：**CRUSH 决定一个 PG 落在哪几块盘，PG 决定哪些 object 共用这次决定。**

### 问题 12：CRUSH 是什么？

**CRUSH** = Controlled Replication Under Scalable Hashing，计算数据放置位置的算法。

给定集群拓扑（机房 / 机柜 / 主机 / OSD）和池的规则（几副本、故障域），对一个 PG **哈希出该放哪几块盘**。

关键特性：客户端和每个 OSD **各自都能算出同一结果**，没有一张「对象在哪」的中心表。

好处是扩容和故障时只迁移受影响的那一小部分，不需要全量重分布；也不存在中心元数据服务这个单点。

那份规则长这样：

```json
{
  "rule_name": "vm-pool",
  "steps": [
    { "op": "take", "item_name": "default" },
    { "op": "chooseleaf_firstn", "num": 0, "type": "host" },
    { "op": "emit" }
  ]
}
```

`chooseleaf_firstn ... type: host` 是关键的一行：**先挑主机，再在主机里挑盘**。所以同一个 PG 的 3 份不会落在同一台机器上。

### 问题 13：PG 和 OSD 是多对多吗？

是，多对多，但不是随便连，是 CRUSH 算出来的。

- **一个 PG**：副本池固定落在 N 个 OSD（N = 池的 size），1 主 + N-1 从
- **一个 OSD**：上面同时住着很多 PG，常见几百到几千个

```text
PG 3.7a  →  OSD1 主  OSD4     OSD7
PG 3.7b  →  OSD2 主  OSD4     OSD9     ← OSD4 同时承载好几个 PG
PG 3.7c  →  OSD1 主  OSD5     OSD8     ← OSD1 也是
```

同一 PG 的副本不会在同一 OSD 上——通常还会避开同一主机。

### 问题 14：一个 PG 用 3 个 OSD，是因为 3 副本吗？

是，但要说准确：**OSD 个数由池的 `size` 决定，不是 PG 自己决定的。**

那个业务池写的是 `replicated size 3`，所以它的每个 PG 落在 3 个 OSD 上。同一个集群里的 `.mgr` 池是 `size 1`，它那个 PG 就只落在 1 个 OSD 上——这是反证。

```text
池 vm-pool   size 3  →  PG 落 3 个 OSD
池 .mgr      size 1  →  PG 落 1 个 OSD
```

措辞上也别叫「3 备份」。是 **1 主 + 2 副本**，共 3 份完整数据：

```text
PG 6.7f
  osd.15  主    收写，再转发给副本
  osd.19  副本
  osd.4   副本
```

改池的 `size` 就改这个数。`size 4` → 每 PG 4 个 OSD。CRUSH 规则再决定这 4 个是不是不同主机。

`size` 和 `min_size` 是两回事：`size 3 min_size 2` 表示挂 1 份还能写（PG 变 `degraded`），挂到只剩 1 份才停写。

纠删码池不是这个规律：那里是 `k + m` 个，k 份数据加 m 份校验，不是 N 份完整拷贝。

### 问题 15：一个 PG 的容量由什么决定？

这里「大小」有两个含义，要分开。

**含义一：成员数（落几个 OSD）** = 池的 `size`。问题 14 已经说完了。

**含义二：容量（装多少字节）** = **没有这个配置项**，是算出来的：

```text
PG 容量 ≈ 池里逻辑数据 / pg_num
       = 对象数 × 单对象大小 / pg_num
```

实测数字：

```text
对象大小      4194304 B = 4 MiB
对象数        55.16k
池逻辑数据    55.16k × 4 MiB ≈ 215 GiB    ← ceph 报 213 GiB ✓
pg_num        128

每 PG 容量    ≈ 215 GiB / 128 ≈ 1.68 GiB
每 PG 对象数  ≈ 55160 / 128   ≈ 431 个
每 PG 裸占    ≈ 1.68 × 3      ≈ 5.0 GiB   （3 副本）
```

同一个池子有三个「占用」数字，差的是副本倍数，别混：

```text
rbd du 的实占        213 GiB   各镜像本层之和，逻辑口径
ceph 报的 STORED     213 GiB   同一个东西，Ceph 自己的算法
ceph 报的 USED       638 GiB   约等于乘上 3 副本，真正吃掉裸容量的量
```

这几个数是同一次测量的快照。加一块盘、起一台虚拟机都会动，过一阵再看就不一样了。

所以真正需要调的是 **`pg_num`**，不是「PG 大小」。想让每 PG 降到 1 GiB，就把 `pg_num` 翻倍。

两个提醒：

- 1.68 GiB 是**均值**。对象按名字哈希进 PG，分布不均匀，有的 PG 装四五百个对象，有的一百多。
- PG 本身**没有 size 字段**。`ceph df` 只给池的总数，不会给单个 PG 的字节数。

### 问题 16：PG 和 OSD 的对应关系会不会漂？

会。CRUSH 是确定性的函数，但它的输入会变：加盘、掉盘、改 reweight、改规则，输出就变。

这个集群里有两个 OSD 的 reweight 是 `0.96999`（`osd.3` 和 `osd.5`）。

**reweight 是给某个 OSD 的权重乘一个系数**，用来微调它分到多少数据。降低它，原本该落在这块盘的 PG 会有一部分迁走。

它不是故障标记。`up` / `in` 才是，那表示「进程在运行」和「参与分配」。

---

## 第三部分：回到上面，CDI 是什么

第一部分留下了 DV 是谁在实现的问题。现在可以回答了。

### 问题 17：CDI 是什么？和 DV 的逻辑关系？

**CDI** = Containerized Data Importer，KubeVirt 的子项目，一个 operator 全家桶。

它的职责只有一句：**把数据导入 PVC。**

**CDI 是一组控制器，DV 是它处理的自定义资源。** 两者不是同一层东西。

CDI 注册的这一串自定义资源：

```text
datavolumes          ← DV 本体
datasources          ← 可复用的数据源，给虚拟机模板引用
dataimportcrons      ← 定时拉新镜像（例如每月的新版基础镜像）
objecttransfers      ← 导出、迁出
storageprofiles      ← 记录每个 StorageClass 能用什么克隆手段
volumeclonesources   ← 哪些 PVC 允许被克隆
volumeimportsources
volumeuploadsources  ← 允许上传
```

四个组件各管一段：

```text
cdi-operator      装、升级 CDI 自己
cdi-deployment    真正的控制器：建 PVC、起 importer/cloner/uploader pod
cdi-apiserver     上传 token、CDI 子资源 API
cdi-uploadproxy   上传的 HTTPS 入口
```

完整流程：

```text
你写 DV（声明：数据从哪来、放进多大的盘）
      ↓
CDI 控制器读 DV
      ├─ 建 PVC
      ├─ 起 importer / cloner / uploader pod
      ├─ pod 把数据写进去（含 qcow2 → raw 转换）
      └─ 回写 DV.status.phase
      ↓
DV 变 Succeeded，PVC 就绪 → 挂给虚拟机
```

**DV 不承载数据。** 它只描述流程，真正的字节在 PVC → PV → Ceph RBD 里。

集群里有个真实的 DV：

```yaml
# default/cloud-image-dv    phase: Succeeded
source:
  http:
    url: https://<镜像站>/.../cloud-image.qcow2
storage:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 20Gi
```

CDI 拉这个 qcow2，在 importer 里转成 raw，再写进 20Gi 的 RBD。

**这一步是 DV 相对裸 PVC 的核心增量**：CSI 克隆只能以另一块 PVC 为源，CDI 能从 HTTP、S3、镜像仓库拉取，能转换镜像格式（qcow2 → raw），还能定时同步。

### 问题 18：那这个平台走的是 DV 还是 PVC？

**日常起虚拟机那次克隆走 PVC，CDI 没参与。** 从 URL 导新底才用 DV，那是后来的事（问题 29）。

当时的三条证据：

```text
业务命名空间里只有 vm-template 这一个 PVC，没有任何 DV
PVC 用 spec.dataSource.kind: PersistentVolumeClaim
storageprofile/ceph-block → cloneStrategy: csi-clone
```

所以那次克隆是 **Ceph CSI 做的**。CDI 只是在 storageprofile 里登记了「这个 class 支持 csi-clone」，只是登记，不执行。

```diff
 CDI 的 DV 路线
- DataVolume → CDI 控制器 → PVC + importer pod → 数据
+ 能力：懂 qcow2、能从 HTTP/S3/registry 拉、能定时同步

 这个平台走的路线
+ PVC.dataSource → CSI clone → 新 PV
+ 少一层控制器，代价是要求模板 PVC 同命名空间、同 StorageClass
```

两者是替代关系，不是叠加。**要克隆就用 `dataSource` 让 CSI 干；要从外部拉镜像才需要 DV/CDI。** 日常新建虚拟机始终是前一条；后一条只在换基础镜像时走一遍。

时间线也支持这个结论：查克隆来源的时候，CDI 刚装两天，而当时在用的模板 PVC 已经 33 天和 126 天。那些克隆不可能是 CDI 做的。

---

## 第四部分：在集群上把这些数出来

前面的结论都可以在现场验证。这套命令值得留下来。

### 问题 19：怎么看集群的整体健康？

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s
```

```text
  cluster:
    health: HEALTH_OK
  services:
    mon: 3 daemons, quorum a,b,c
    mgr: b(active), standbys: a
    osd: 24 osds: 24 up, 24 in
  data:
    pools:   2 pools, 129 pgs
    objects: 55.16k objects, 213 GiB
    usage:   673 GiB used, 2.3 TiB / 3 TiB avail
    pgs:     128 active+clean
             1   active+clean+scrubbing+deep
```

先看 `health`，再看 `pgs` 那行是不是全 `active+clean`。

一个运维习惯：**`ceph -s` 里的 pg 状态比 `ceph health` 更早暴露问题**。`active+clean` 是健康终态；出现 `degraded`、`peering`、`remapped`、`undersized` 都说明有副本没到位。

上面那行 `active+clean+scrubbing+deep` 不是异常——深层校验正在跑，基础状态仍是 `active+clean`。后缀常见的是 `scrubbing`、`snaptrim`、`backfill`。

### 问题 20：怎么看 OSD 分布在哪几台机器？

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree
```

```text
ID  CLASS  WEIGHT   TYPE NAME       STATUS  REWEIGHT
-1         3.00000  root default
-3         1.00000      host 节点A
 1    hdd  0.12500          osd.1       up   1.00000
 ...
-5         1.00000      host 节点B
 0    hdd  0.12500          osd.0       up   1.00000
 ...
-7         1.00000      host 节点C
 3    hdd  0.12500          osd.3       up   0.96999
 ...
```

读数：

- 3 台主机，每台 8 块盘，共 24 个 OSD
- 每块盘权重 0.125，每台合计 1.0，整个集群 3.0 TiB
- 全部 `up`，全部 `in`
- `osd.3`、`osd.5` 的 reweight 是 `0.96999`（问题 16）

注意一点：**集群有四台节点，但 Ceph 只用了其中三台。** 有一台不存数据。这是设计选择，不是配置错误。

### 问题 21：怎么看每个 OSD 承载多少个 PG？

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd df
```

```text
ID  CLASS  WEIGHT   REWEIGHT  SIZE     RAW USE  DATA     OMAP     META      AVAIL    %USE   VAR   PGS  STATUS
 1    hdd  0.12500   1.00000  128 GiB   30 GiB   29 GiB   36 KiB  1013 MiB   98 GiB  23.12  1.06   17      up
 7    hdd  0.12500   1.00000  128 GiB   27 GiB   25 GiB   42 KiB   1.5 GiB  101 GiB  20.95  0.96   15      up
...
                       TOTAL    3 TiB  673 GiB  638 GiB  906 KiB    35 GiB  2.3 TiB  21.89
MIN/MAX VAR: 0.82/1.28  STDDEV: 3.65
```

几张表的信息不一样：

| 列 | 含义 |
| --- | --- |
| `SIZE` / `AVAIL` | 这块盘的物理容量和剩余 |
| `RAW USE` | 实际占用（含副本和元数据） |
| `DATA` | 上面的用户数据 |
| `META` | RocksDB 等元数据，通常 1–2 GiB |
| `PGS` | 这个 OSD 上住着多少个 PG |
| `VAR` | 与集群均值的偏离倍数 |
| `STDDEV` | 整体分布的标准差 |

实测的 PG 数范围是 **13–21 个**，正好对上问题 15 那个公式：

```text
每 OSD 的 PG ≈ pg_num × size / OSD 数 = 128 × 3 / 24 = 16
```

`VAR` 在 0.80 到 1.30 之间，说明分布基本均衡。

### 问题 22：怎么直接看 PG 落在哪几个 OSD 上？

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph pg dump pgs_brief
```

```text
PG_STAT  STATE         UP          UP_PRIMARY  ACTING      ACTING_PRIMARY
6.7f     active+clean  [15,19,4]          15   [15,19,4]              15
6.7e     active+clean     [5,7,3]           5     [5,7,3]               5
6.37     active+clean    [1,7,14]           1    [1,7,14]               1
6.36     active+clean   [18,2,17]          18   [18,2,17]              18
6.35     active+clean     [4,8,1]           4     [4,8,1]               4
6.34     active+clean    [8,13,7]           8    [8,13,7]               8
```

注意 `UP` 和 `ACTING` 在这几行里是一样的。**不一样就说明正在迁移或正在恢复**，那是排查故障的入口。

列表里的数字是 OSD 编号。把它们翻译成主机：

```text
osd.1,2,5,9,10,11,13,15  →  节点 A
osd.0,4,7,12,16,18,20,22 →  节点 B
osd.3,6,8,14,17,19,21,23 →  节点 C
```

| PG | acting set | 落在哪几台机器 |
| --- | --- | --- |
| 6.7f | 15, 19, 4 | A, C, B |
| 6.7e | 5, 7, 3 | A, B, C |
| 6.37 | 1, 7, 14 | A, B, C |
| 6.36 | 18, 2, 17 | B, A, C |
| 6.35 | 4, 8, 1 | B, C, A |
| 6.34 | 8, 13, 7 | C, A, B |

**每一行都是三台机器各一个，没有同一台出现两次。** 这就是问题 12 里 `chooseleaf host` 那一行的效果。

要查单个 PG：

```bash
ceph pg map 6.7f
# pg 6.7f (6.7f) -> up [15,19,4] acting [15,19,4]
```

### 问题 23：怎么确认池的副本数和 PG 数？

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd pool ls detail
```

```text
pool 6 'vm-pool'  replicated size 3 min_size 2 crush_rule 2 \
     pg_num 128 pgp_num 128 autoscale_mode on application rbd
pool 4 '.mgr'     replicated size 1 min_size 1 crush_rule 0 \
     pg_num 1 pgp_num 1 autoscale_mode on application mgr
```

| 字段 | 含义 |
| --- | --- |
| `size` | 每 PG 几份数据（问题 14） |
| `min_size` | 低于几份就停止写入 |
| `crush_rule` | 用哪条 CRUSH 规则选盘 |
| `pg_num` / `pgp_num` | PG 总数 / 参与哈希的 PG 数，通常相等 |
| `autoscale_mode` | 是否允许集群自动调 `pg_num` |
| `application` | 这个池给谁用（`rbd`、`cephfs`、`rgw`） |

`vm-pool` 是虚拟机盘池，`.mgr` 是监控自己用的。

**`.mgr` 是理解 size 的最好反例**：`size 1`，所以它那 1 个 PG 只落在 1 个 OSD 上。

### 问题 24：经验公式说 PG 要 800，为什么这里只有 128？

常见经验公式是：

```text
PG 数 ≈ OSD 数 × 100 / 副本数 = 24 × 100 / 3 = 800
```

这里只有 128。这不是算错，而是这个公式的适用场景不同。

那条公式服务的是**大池、高并发、需要把负载摊到足够多 PG 上**的场景。这里的池只有两百多 GiB、5 万多个对象，128 个 PG 已经让每个 OSD 分到 16 个，分布也均衡（`VAR` 最大 1.30）。

看 autoscale 的实际建议：

```bash
ceph osd pool autoscale-status
```

```text
POOL      SIZE     TARGET SIZE  RATE  RAW CAPACITY  RATIO  PG_NUM  NEW PG_NUM  AUTOSCALE
.mgr      904.0k                1.0    3072G       0.0000       1              on
vm-pool   206.3G                3.0    3072G       0.2015     128              on
```

`NEW PG_NUM` 是空的，说明它算下来也认为**不用改**。

但要注意 `TARGET SIZE` 和 `TARGET RATIO` 都是空的。autoscale 没有设定目标，就缺少向上扩容的依据。**池将来真的长大了，不能指望它自己动。** 这是我的判断，不是实测结论。

### 问题 25：怎么确认对象真的是 4MiB？

```bash
rados -p vm-pool stat <object>
```

见问题 10。抽查五个对象，全是 `size 4194304`。

---

## 第五部分：几个值得记住的坑

### 问题 26：CSI 克隆有什么限制？

`dataSource.kind: PersistentVolumeClaim` 这条路要求：

1. **模板 PVC 和新 PVC 在同一个命名空间**
2. **两者用同一个 StorageClass**
3. **两者 `volumeMode` 相同**（Filesystem 不能当 Block 的源，反过来也不行，问题 34）
4. 新 PVC 的容量不小于模板（精确到字节的规则见问题 32）

第 1 条是第 8 问里没提、但实际会限制用法的条件。它解释了为什么每个环境命名空间里都各存一份 `vm-template`：

```text
env-dev    vm-template        42Gi  Bound    ← 旧模板
env-dev    vm-template-2403   45Gi  Bound    ← 从 URL 导入新建的那份
env-os     vm-template        42Gi  Bound
env-test   vm-template        42Gi  Bound
```

不是冗余，是硬性要求。跨命名空间克隆直接被拒绝。

### 问题 27：troubleshooting 时先看哪三个命令？

```text
1. ceph -s                    健康、PG 状态、容量
2. ceph osd df                哪块盘偏满、哪个 OSD 承载的 PG 多
3. ceph pg dump pgs_brief     UP 和 ACTING 是否一致
```

前两个看「整体」，第三个看「具体的 PG 有没有在迁移」。

`ceph osd df` 里的 `VAR` 是最有用的一个数字：某块盘的 `VAR` 明显高于其它，通常是它的 reweight 被人为调过，或者盘本身有健康问题。

### 问题 28：rook-ceph-tools 的版本和集群不一致要紧吗？

```text
集群守护进程：squid (19.x)
tools 容器客户端：reef (18.x)
```

**`rook-ceph-tools` 的镜像比集群本体旧了一个大版本。**

大多数只读命令（`ceph -s`、`osd df`、`pg dump`）不受影响，因为协议向后兼容。但这意味着：

- 依赖新版本才有的命令或字段时，可能拿不到或报错
- 写操作（`osd pool set` 之类）要谨慎，客户端版本差异可能带来意外

结论：**查问题用它没问题，改配置最好用与集群版本匹配的客户端。**

---

## 第六部分：导入与克隆，尺寸怎么定

前面分开了两条路：日常克隆走 CSI，从 URL 拉镜像才走 DV。下面把导入、尺寸、`volumeMode` 和链一次问完。

### 问题 29：从 URL 导入一块 PVC，中间发生了什么？

```text
DataVolume（一个 URL）
  ├─ CDI 生成一个 VolumeImportSource，把 URL 包成自定义资源
  │    目标 PVC 的 spec.dataSource 指向它
  ├─ 控制器开一块 prime PVC —— 真正被写入的盘
  ├─ 压缩源再开一块 scratch PVC
  ├─ importer Pod：HTTP GET → 认出 qcow2 → 流式解压 → 转成 raw → 写入
  └─ 完成后把内容交给目标 PVC，prime 与 scratch 回收
```

prime 和 scratch 都是临时盘，可以直接验证：导入期间 `kubectl get pvc` 会多出 `prime-<uid>` 和 `prime-<uid>-scratch`，导入完成后消失。

**为什么需要 scratch。** gz、xz 这类压缩源要先把数据解开才能转换，解压和转换不能安全地直接落到目标盘上，中间需要一块盘。所以压缩源的导入会同时占 prime 和 scratch 两块。

scratch 的 storage class 取自 `CDIConfig` 的 `scratchSpaceStorageClass`；这个集群没有配，于是回落到目标 PVC 用的那个 class。尺寸由目标尺寸推导。

**两个阶段在日志里分得开。**

```text
下载   DV 的 status.progress 涨到 99.5% 然后停住
转换   importer 日志换成 qemu.go 的百分比，从 0 重新涨
```

实用结论：`progress` 停在 99.x% 不动不是卡住，是在把 qcow2 转成 raw。这个阶段按镜像里实际有多少数据耗时，不按虚拟盘大小。

**写进去的那个 raw 就是 `disk.img`。** Filesystem 模式下，importer 把转换结果写成 PVC 上的这个文件；qcow2 只是下载来的源，转换完就没了。Block 模式下没有这个文件，raw 直接写进 RBD 块设备。

### 问题 30：CSI 克隆是全量复制还是 COW？

**是 COW。** 实现方式是 RBD 快照加 `rbd clone`。

证据取自最新那条链。它现在只挂了 1 个克隆，但层数、命名规则和父子关系跟挂着十八个克隆的老链完全一样——多克隆叠加的效果见问题 35：

```text
rbd info <模板>
  op_features: clone-parent, clone-child, snap-trash
  parent: vm-pool/csi-vol-<...>-temp@<快照>

rbd du -p vm-pool
  csi-vol-<链根>            声明 43 GiB   实占 2.0 GiB     ← 最下面那张，自己没有父
  csi-vol-<模板>-temp       声明 43 GiB   实占 0 B
  csi-vol-<模板>            声明 45 GiB   实占 404 MiB
  csi-vol-<克隆>-temp       声明 45 GiB   实占 0 B
  csi-vol-<克隆>            声明 45 GiB   实占 104 MiB
```

**每个逻辑克隆对应两块 RBD 镜像。** 控制器分两步：先把源快照 COW 克隆成一块临时镜像，再从临时镜像的快照 COW 克隆出目标镜像。所以一条完整的链是五层：

```text
csi-vol-<链根>                      声明 43Gi   实占 2.0 GiB   ← 从 URL 导入时写进去的数据
  └─ csi-vol-<模板>-temp            声明 43Gi   实占 0 B
       └─ csi-vol-<模板>            声明 45Gi   实占 404 MiB   ← 在这块盘上做过一次改动
            └─ csi-vol-<克隆>-temp  声明 45Gi   实占 0 B
                 └─ csi-vol-<克隆>  声明 45Gi   实占 104 MiB   ← 这台虚拟机写出来的部分
```

**右边那列不是「这张图有多大」——每一层都是 43 或 45 GiB 的完整设备镜像。** 那是「这一层自己写了多少」。

**同一层链里 `声明` 可以不一样，这不矛盾。** 规则是：**临时层继承源的尺寸，最终那层是本次申请的尺寸**：

```text
链根                 43Gi   ← 当初导入时定下的 PV
  └─ <模板>-temp      43Gi   ← 继承源（链根）
       └─ <模板>      45Gi   ← 克隆它的时候申请的
            └─ <克隆>-temp  45Gi   ← 继承源（模板）
                 └─ <克隆>  45Gi   ← 这次申请的
```

声明尺寸是「这块盘多大」，跟层与层之间的数据关系是两件事。

**RBD 一步就能 clone，`-temp` 是 CSI 插进去的。** 45Gi 克隆 45Gi 时这张空图照样在，所以它不是为了改尺寸。

CSI 要一张**永远不会被 map 到节点上**的图，专门用来 flatten。链太长时要把父层对象拷进某张图、断开 `parent`（见问题 36）；flatten 正在被虚拟机用的盘会卡住 IO。`-temp` 带 `deep-flatten`，最终那张（StorageClass 只开了 `layering`）没有。设计就是：flatten 临时图，不 flatten 给用户 map 的那张。

尺寸差是两步的副产品：`rbd clone` 出来的图跟父一样大，所以 temp 继承源的声明尺寸；最终那张再 resize 到 PVC request。

**只有写过的层才存 COW 内容。** temp 实占 0 B，没人往里写。链根是导入时写进去的全量，不是差量。KubeVirt / libvirt 不参与建链；它们只在有人开机往盘上写的时候出现（问题 38）。

**`rbd du` 报的是「本层」。** 它只统计这个镜像自己占的对象，不含父层。要问「这条链一共占多少」，得沿 `parent` 一路加到链根。

**粒度是 4 MiB 的对象。** 占用量正好等于「对象数 × 4 MiB」，一个字节不差：

```text
<模板>   本层  101 个对象 = 404 MiB        101 × 4 MiB = 404 MiB
<克隆>   本层   26 个对象 = 104 MiB
```

所以客户机写 4 KiB，如果落在一个还住在父层的对象里，OSD 会把**整个 4 MiB 对象**复制到子层，再把这 4 KiB 应用上去。这是克隆第一次写到某片区域会慢一点的原因。

三个后果：

- **省空间是真的。** 克隆只付自己写出来的那些块。上面那块虚拟机用了 104 MiB，不是 45 GiB。整个池合计：声明 3.0 TiB，实占 213 GiB。

（声明按 **RBD 镜像**算。按 PVC 算只有 1.6 TiB，差额就是每张 `-temp`——它占着声明容量，却从来没人 mount。）
- **模板不能随便删。** 父快照被保护，模板带着活子卷时删不掉，要先删子卷或者 flatten（机制见问题 36）。模板和克隆之间有依赖。
- **COW 与 volumeMode 无关。** 它是 RBD 层的性质，Filesystem 和 Block 两种模式都省空间。

顺带把一个容易混的印象分清：**从 URL 导入**是真的把字节写进去，**`dataSource` 克隆**是 COW。两者是不同的操作，开销不能放在一起比。

### 问题 31：那些「大小」分别是什么？

一块盘从 URL 到虚拟机，中间经过六个不同的数，名字都像「大小」，来源完全不同。

| 名称 | 含义 | 从哪来 | 谁决定 |
| --- | --- | --- | --- |
| 压缩包 | 下载体积 | HTTP `Content-Length` | 发布方的压缩 |
| 虚拟盘大小 | URL 上下来的 qcow2 声明的盘容量 | qcow2 头部偏移 `0x18` 的 8 字节 | 镜像制作者 |
| 镜像实占 | 镜像里真正写过的块 | 精简置备 | 镜像内容 |
| PVC request | 实际提交的存储申请 | Filesystem：DV 请求 × `(1 + filesystemOverhead)`；Block：等于 DV 里写的数 | 集群配置 |
| PV capacity | 建出来的盘容量 | request 向上取整到 GiB | CSI 驱动 |
| RBD 实占 | 真正占用的块 | 精简置备 + COW | 实际使用 |

虚拟盘大小可以直接从文件里读出来，不必下载整块镜像。qcow2 头部是定长的，`size` 字段在偏移 `0x18`：

```bash
# 压缩源需要先解开前几 MiB 才能读到头部
curl -r 0-6291455 -o head.xz.part <url>
xz -dc head.xz.part 2>/dev/null | head -c 104 > head.bin
xxd -l 64 head.bin
# 00000000: 5146 49fb ...                          magic = QFI\xfb
# 00000010: 0000 0000 0000 0010 0000 000a 0000 0000
#                            ↑cluster_bits  ↑size 从这里开始的 8 字节
```

读出来的 `0x0000000A00000000` 是 `42,949,672,960`，即 40 GiB。**这是源镜像声明的盘有多大**，importer 拿它跟 PVC request 比。客户机后来看见的 vda 是不是这个数，取决于 `volumeMode`：Filesystem 下 `disk.img` 就是这么长；Block 下客户机看到的是整块 RBD，克隆申请更大时会超过 40 GiB（问题 34）。

压缩包小、虚拟盘大，不矛盾：前者是数据被压缩后的体积，后者是镜像声明的容量。实占介于两者之间，取决于镜像是稀疏的还是带着真实数据。

### 问题 32：什么尺寸能导入，什么尺寸能克隆？

两条独立的不等式。**导入看的和克隆看的是同一个数：PVC 的 request。**

导入阶段，importer 会拿源镜像的虚拟大小和目标的 request 比。请求明显过小时它会把两个数都报出来：

```text
virtual image size 42949672960 is larger than the reported available storage 1138166334.
A larger PVC is required
```

- `42949672960` 就是问题 31 里那个虚拟盘大小，40 GiB
- `1138166334` 是 PVC 的 **request**，等于 `1Gi × 1.06`。不是那块 PVC 的 capacity，它的 capacity 是 2Gi

于是两条规则。**下面默认 Filesystem。** 导入那条里的 6% 由 CDI 加在 request 上；克隆那条里没有新的 6%，它只是「目标不小于源」，而源如果是 DV 建的，它的 request 出生时就已经被放大过了。Block 不乘 1.06，见问题 34。

```text
导入   用户请求 × (1 + filesystemOverhead) ≥ 虚拟盘大小
克隆   克隆请求 ≥ 源 PVC 的 request
       └ 源若是 DV 建的，这个 request 就等于 用户请求 × (1 + filesystemOverhead)
```

代入一组实测（虚拟盘 40 GiB，overhead 0.06）：

| 用户请求 | PVC request | PV capacity | 能导入 | 克隆至少要申请 |
| --- | --- | --- | --- | --- |
| 1Gi | 1.06 GiB | 2Gi | 否 | — |
| 39Gi | 41.34 GiB | 42Gi | 是 | 42Gi |
| 40Gi | 42.4 GiB | 43Gi | 是 | 43Gi |
| 42Gi | 44.52 GiB | 45Gi | 是 | 45Gi |

**request 到 capacity 是向上取整到整 GiB。** 表格第一行就是证据：request 是 1.06 GiB，capacity 落在 2Gi，不是 1Gi。

**反过来推想要的那个容量。** 要让 PV 落在 42Gi，request 必须落在 `(41, 42] GiB`，倒推回 DV 里写的数就是 `(38.68, 39.62]`——这个区间里只有一个整数 39。所以 39 不是魔数，是唯一能写的整数；写 40 就出界，PV 变 43Gi。

**那 6% 只影响这两个数，不影响实占。** overhead 让 request 变大，PV 向上取整也跟着变大，但 RBD 是精简置备，多出来的容量不占空间。问题 30 里的池合计就是证据：声明 3.0 TiB，实占 213 GiB。

所以想保住某个容量时，有三条路可走：

1. **顺着 overhead 走。** 请求 40Gi，接受 43Gi 的 PV，克隆尺寸也调到 43Gi 以上。
2. **反向凑。** 请求 39Gi，request 是 41.34 GiB，PV 落在 42Gi，克隆 42Gi 就够。代价是引入一个只看 overhead 才说得通的数字。
3. **把 overhead 置 0。** 改 `CDIConfig` 里这个 storage class 的 `filesystemOverhead`，请求多少就是多少。但声明 40GiB 的盘装不下 40GiB 的文件，importer 的校验会放行，写入时才 ENOSPC。

第 3 条影响该 storage class 上此后所有的 DV 导入，动手前要清楚这一点。

**overhead 不是一个多余的设计。** 文件系统本身要占一部分空间放元数据，声明 42Gi 的盘实际装不下 42Gi 的文件。CDI 用这个比例保证导入的文件放得进去。（那层文件系统是谁建的，见问题 33。）

这套盘最后是这么定的：

```text
DV 里写 storage: 40Gi
  → PVC request 42.4 GiB
  → PV 43Gi            ← 模板实际的大小
  → 克隆尺寸取 45Gi     ← 比 43Gi 多留 2Gi
```

写 40Gi 是因为镜像的虚拟盘就是 40 GiB，这个数在清单里说得通。43Gi 和 45Gi 是它乘上 overhead、再向上取整之后的产物。这是 Filesystem 那条路；同一份镜像用 Block 导入，DV 写 40Gi 就得到 40Gi 的 PV（问题 34）。

### 问题 33：为什么 RBD 镜像上还有一个文件系统？

这一问只针对 `volumeMode: Filesystem`。Block 没有外层文件系统，也没有 `disk.img`（问题 34）。

问题 32 里那 6% 是 CDI 给外层文件系统留的垫子，**不是这层文件系统出现的原因**。`volumeMode: Filesystem` 才会让 CSI 对 RBD 做 mkfs；6% 只是预估格式化之后还剩多少给 `disk.img`。

文件系统可以叠好几层。客户机里那个只是**最里面**的一层，外面还有一层由宿主节点建，客户机不知道它存在。

关键在于 `volumeMode: Filesystem`：CSI 节点插件把 RBD map 成 `/dev/rbdN` 之后，按 StorageClass 的 `csi.storage.k8s.io/fstype` 做 mkfs，再挂进 Pod。客户机不知道有这一步。

实测，从一台正在运行的虚拟机里看到的：

```text
/dev/rbd5  ->  /var/run/kubevirt-private/vmi-disks/<disk>       ext4

/var/run/kubevirt-private/vmi-disks/<disk>/
  disk.img       42949672960 字节 = 40 GiB
  lost+found/                                    ← ext4 根目录必有的东西
```

- `/dev/rbd5` 是 CSI 节点插件 `rbd map` 出来的块设备
- `ext4` 是导入时 CSI 节点插件 mkfs 上去的
- `lost+found` 是 ext4 的标志，证明这一层确实是 ext4
- `disk.img` 就是虚拟机的盘，一个 40 GiB 的文件

**为什么要多这一层：** 因为要往里放一个文件。文件必须住在文件系统里。

```text
客户机的根文件系统              虚拟机内核管的。客户机以为这就是它的盘
        ↑ 装在这个文件里
disk.img / 40 GiB               Pod 里的一个普通文件
        ↑ 住在这个文件系统上
/dev/rbd5 上的 ext4             宿主节点的 kubelet 建的
        ↑
RBD 镜像                       COW 克隆
        ↑
RADOS 对象 / PG / OSD
```

**QEMU 读的恰好就是那个文件。** 它的命令行写得很明白：

```text
-blockdev
{"driver":"file","filename":"/var/run/kubevirt-private/vmi-disks/<disk>/disk.img", ...}

-device
{"driver":"virtio-blk-pci-non-transitional", "drive":"libvirt-1-storage",
 "id":"ua-<disk>", "bootindex":1, ...}
```

第一行：宿主把 `disk.img` 当**文件**打开，走的是外层 ext4。
第二行：把它的字节当一块 `virtio-blk` 盘交给客户机，而且 `bootindex: 1`——客户机从它启动。

所以客户机启动读的是 `disk.img` 的字节，压根不碰外层 ext4。外层 ext4 存在的唯一理由，是宿主需要能 `open()` 一个文件交给 QEMU。

两块 ext4，建的层次不同：

| 文件系统 | 谁建的 | 装什么 |
| --- | --- | --- |
| RBD 上的 ext4 | 宿主节点的 kubelet | 一个 `disk.img` |
| 客户机里的文件系统 | 虚拟机内核 | `/etc`、`/bin` 这些 |

`disk.img` 的前 8 字节是 `00 00 00 00 00 00 00 00`，不是 `QFI\xfb`。所以它不是 qcow2 了——导入时已经转成 raw。raw 的长度就等于虚拟盘大小，40 GiB 是这么来的，也对上了问题 31 里读到的那一个数。

**`/dev/rbdN` 和 `disk.img` 不是同一个东西。** CSI 把 RBD 镜像 map 成块设备；ext4 做在这块设备上；`disk.img` 是这个文件系统里的一个文件。QEMU 打开的是文件，不碰 `/dev/rbdN`。

```text
RBD 镜像              CSI 节点插件 rbd map 成 /dev/rbdN
  → mkfs.ext4         导入时做过一次
      → disk.img      40 GiB 的 raw 文件，QEMU 打开它
          → 客户机的 vda
```

RBD 声明 43Gi，`disk.img` 40 GiB，差的是那 6% 垫子，不是两块盘。

**外层 ext4 是导入时建的，不在克隆层里。** importer Pod 第一次挂这块 PVC 时，CSI 节点插件对裸设备 mkfs.ext4，再把转换出来的 raw 写成 `disk.img`。之后开机只 map、只挂，不再 mkfs。模板和克隆是 COW，ext4 已经在链根里。克隆本层只有后来写过的块。开机这条挂载路径见问题 38。

**这一层和 COW 没有关系。** `layering` 和 `fstype` 并排躺在同一个 StorageClass 里：

```text
StorageClass/ceph-block 的 parameters:
  imageFeatures                  layering     ← COW 的开关
  imageFormat                    2
  csi.storage.k8s.io/fstype      ext4         ← 文件系统类型
```

`layering` 是块层的：RBD 镜像带这一位才允许做 COW 克隆，克隆的 `op_features` 里会写 `clone-parent` / `clone-child`。

上面那层 ext4 不削弱它。RBD 的 COW 作用在**块**这一层，只认「第 N 个块被写过没有」；上面盖的是 ext4、qcow2 还是裸数据，它不关心。

「文件系统用不了 COW」这个印象多半来自 ext4 没有 reflink——XFS 和 btrfs 支持文件级的写时复制，ext4 不支持。那是文件系统层的 COW，和块层的这一套是两件事。

### 问题 34：volumeMode 选 Filesystem 还是 Block？

`volumeMode` 只有两个值，说的是**卷以什么形态交给容器**，不是「盘里存的是文件还是块」——两种模式的底层都是同一个 RBD 镜像，区别只在交给 Pod 之前做不做格式化。

| | `Filesystem` | `Block` |
| --- | --- | --- |
| 交给容器的东西 | 一个目录 | 一个设备节点（KubeVirt 里是 `/dev/pvcdisk`） |
| kubelet 做的处理 | 首次 mkfs，之后只挂载 | 不格式化、不挂载，映射设备 |
| 容器里怎么用 | 按文件读写 | 直接读写块 |
| 宿主上的块设备 | `/dev/rbdN`，被挂载 | `/dev/rbdN`，被映射进容器 |

**这和前面那 6% 直接相关。** `filesystemOverhead` 的名字里就写着 Filesystem——只有存在外层文件系统时才需要它。选 Block 就没有那层 ext4，字节直接写进裸设备，request 是多少就是多少。

实测问题 17 里那块 `cloud-image-dv`，它是 Block 模式：

```text
DV 里写          storage: 20Gi
PVC 的 request   21474836480 字节 = 正好 20 GiB      ← 没有乘 1.06
PVC 的 capacity  20Gi
```

对比问题 32 的表格：Filesystem 模式下写 `1Gi`，得到的 request 是 `1.06 GiB`。

**但 Block 也躲不掉 6%，只是挪了个地方。** 用同一个 40 GiB 的镜像导两遍，只改 `volumeMode`：

```text
                    Filesystem                 Block
DV 里写              storage: 40Gi               storage: 40Gi
PVC 的 request       45,526,653,338 字节         42,949,672,960 字节
                     ↑ 乘了 1.06                  ↑ 没乘
PV 的 capacity       43Gi                       40Gi
PV 的 fsType         ext4                       （空）
里面                 ext4 + disk.img             raw 直接躺在块设备上
```

两边写进盘的字节完全相同——各读前 64 MiB 做哈希，值一样；MBR 分区表也一样。差别只在那层 ext4，和它带来的 3Gi。

但这次导入的源是 `.xz` 压缩包，CDI 要开一块 scratch 先解开再转换。实测那块 scratch 是 **Filesystem** 模式的，43Gi，照样带着 1.06：

```text
prime     Block       40Gi    和目标是同模式
scratch   Filesystem  43Gi    ← 压缩源才有，导完即回收
```

那张 Block 的底是一张独立的链根。同一套「克隆一层再开机改登录方式」的工序，在它上面也走得通——问题 37、问题 38。

**一次克隆的两端不能混模式。** 源是 Filesystem，目标就不能是 Block，CSI 会拒。这和「集群里能不能两种都有」不是一回事：四十多个 Filesystem 和几块 Block 已经同时活着。旧虚拟机从旧模板克隆，碰不到一份还没人用的新模板。

克隆 PVC 的 `volumeMode` 必须和源相同，清单里写明最稳妥。正在被克隆的旧模板要换模式，才是「要么全换，要么不换」——模式和模板得一起切。

**客户机看见的盘有多大，两种模式不一样。** 这是选模式时真正要权衡的，不是那 6%。

```text
                    Filesystem                      Block
kubelet             挂载                            映射设备（MapPodDevice）
交给容器            一个目录                         /dev/pvcdisk
libvirt             type='file'                     type='block'
QEMU 打开           .../disk.img                    /dev/pvcdisk
QEMU 参数           cache=none                      cache=none  io='native'
客户机的 vda        = disk.img = 40G                = 整块 RBD = PVC 多大就多大
多出来的容量        外层 ext4 里，客户机看不见       盘尾没分区的空间，客户机看得到
```

Filesystem 下 PVC 申请 45Gi，客户机仍然是 40G 的 vda——多的 5Gi 被外层 ext4 吃掉了。Block 下同一份 45Gi 克隆，客户机 `lsblk` 看到 45G 的 vda，分区仍是镜像里的 2G + 38G，后面约 5G 空着，可以扩。

**一个顺序造成的坑。** CDI 不写 `volumeMode` 时，从 StorageProfile 的 `claimPropertySets` 里挑第一条和 `accessModes` 相符的。这个 class 有三条：

```text
[0] ReadWriteMany / Block
[1] ReadWriteOnce  / Block
[2] ReadWriteOnce  / Filesystem
```

只写 `ReadWriteOnce` 会命中 `[1]`，拿到 **Block** 而不是 Filesystem——上面那块 `cloud-image-dv` 就是这么建的。**Filesystem 排在最后**，所以要它必须自己写明。

### 问题 35：链根、模板、克隆是什么关系？

问题 30 只画了链的一段。补上最下面那层，关系才完整。

**链根**（一条 `parent` 链最底下那张图，自己没有父）是一块**完整的设备镜像**，它自己就能读。克隆不是——克隆只持有自己改动过的对象，缺的部分每次读都要向链根要。所以：

- 链根能单独活
- 克隆不能：链根没了，克隆读到一半就报 I/O 错误

设备层看不见这个依赖。宿主看到 `/dev/rbd5` 就是一块完整的 45 GiB 盘，父子之间的穿梭在驱动里做掉了。只有链根被删的那一刻才暴露出来。

**一个链根可以挂很多克隆，它们互相看不见。** 一台虚拟机删掉一个文件，另一台那边那个文件还在——删除只写进它自己那层。

这个集群上的实际情况（从每块 PVC 沿 `parent` 追到根）：

```text
链根 A（PVC 42Gi，本层约 40 GiB；本身也是 env-dev 的模板）  21 块 PVC
  ├─ env-dev 的模板                          就是它自己
  ├─ env-dev 的 1 台虚拟机
  ├─ env-os 的模板
  └─ env-os 的 18 台虚拟机

链根 B（PVC 42Gi，本层约 40 GiB；本身也是 env-test 的模板）  12 块 PVC
  ├─ env-test 的模板
  └─ env-test 的 11 台虚拟机

链根 C（PVC 43Gi，本层 2.0 GiB；Filesystem 干净底）          3 块 PVC
  ├─ env-dev 的新模板（45Gi）
  └─ env-dev 的 1 台虚拟机

链根 D（PVC 40Gi，本层 1.8 GiB；同一份镜像 Block 导入）      2 块 PVC
  └─ env-dev 的 Block 模板（45Gi）
```

所以链根不止一个：每个环境都有自己的链，env-dev 因为新旧模板、两种 `volumeMode` 并存横跨几条。注意链根 A 同时也是 env-dev 的模板，env-os 整条链挂在它下面——跨命名空间，CSI 自己做不到，所以那是手工建出来的依赖。

**链根和它上面那层之间，差的往往只是一次改动。** 链根是「原厂镜像的字节」，往上一层的模板是「在这块盘上又做了点事」，两者之差就是改动量：

```text
链根 C 的本层 2.0 GiB       从 URL 导入的原始镜像
  → 模板的本层 404 MiB      在这块盘上做的改动（改了配置、装了东西）
  → 克隆的本层 104 MiB      第一台虚拟机开机以后写出来的
```

所以「新模板是从哪来的」这个问题，答案不是「另导了一份」，而是「在链根上多写了 404 MiB」。同一块盘的三个时间点，Ceph 只存差量。

**各层相加可以超过设备大小。** 这是最容易算错的一处。取一个改得很猛的克隆——这套数来自更早的那条链，链上设备是 42 GiB：

```text
链根      10289 个对象 = 40.2 GiB
克隆       6026 个对象 = 23.5 GiB
──────────────────────────────────
各层相加                  63.7 GiB   ← 超过 42 GiB
并集（重叠只算一次）       40.4 GiB   ← 设备里真正装了东西的部分
差 = 重叠                 23.3 GiB
```

**那些层不是「装在 42 GiB 盒子里的东西」，是同一块盘的多个版本。** 克隆写过的区域，链根那份不会释放——对别的克隆还有用，对自己只是被遮住。链上对象之和记的是各层各自持有的量，被遮住的算两遍。

所以「各层相加」没有上限关系（理论上可以到层数 × 42 GiB），只有「并集」才必须 ≤ 42 GiB。

**而且那 6026 个对象里，5964 个（99%）盖在链根已有的区域上，只有 62 个是全新的。** 这台虚拟机几乎没往里加东西，它把原有的 23.3 GiB 重写了一遍。设备上的内容只多了 0.2 GiB，链上却多出 23.3 GiB。

**本层占用是碰过的对象之和，不是客户机现在用了多少。** 删掉的文件不会把对象还回去。量级可以看这三个点：

```text
只挂载过、从没启动虚拟机     2 个对象 = 8 MiB      旧链的模板，就格式化了一下
刚建出来、开过一次机的一台克隆  26 个对象 = 104 MiB   新链
在那块盘上做过一次改动        101 个对象 = 404 MiB  新链的模板
```

### 问题 36：COW 的开关在哪里？为什么模板删不掉？

问题 30 说「父快照被保护」，但 `rbd snap ls` 在源图上返回空。快照在哪？

```text
rbd info <链根>
  snapshot_count: 1
  op_features: clone-parent, snap-trash

rbd snap ls --all -p vm-pool <链根>
  NAME                      SIZE    PROTECTED  NAMESPACE
  a1b2c3d4-…-e5f6a7b8c9d0   43 GiB             trash (csi-vol-<模板>-temp)
```

**快照被移进了 trash 命名空间。** 所以普通列表里看不到，`PROTECTED` 那列也是空的——这一版不用老的 `rbd snap protect`，改成「快照进 trash + 子图引用它」。`op_features` 里的 `snap-trash` 就是它在用这个机制。

于是一次 CSI 克隆 = **源图上一个快照（藏进 trash）+ 一张引用它的子图**。这把两件事解释清楚了：

- **快照数 = 子卷数。** env-os 的模板上有 18 个 trash 快照，对应挂在它下面的 18 个克隆；新建的那份是 1 个，对应它唯一那台克隆。快照的时间戳就是每个克隆建立的时刻。
- **模板删不掉。** 那 18 个快照是 18 个克隆的锚点。子卷处理掉（删掉或者 flatten）之后，快照才会跟着走——但**不是立刻**：删掉克隆的那一刻快照还在，过一会儿才消失。核对方法是比「活子卷数」和「trash 快照数」，现在三份模板两边都相等（18/18、11/11、2/2），说明没有泄漏。

**flatten 做什么。** 把父层里这份图还在用的对象拷进自己，然后断开 `parent`。之后这张图不依赖上面任何一层，父可以删。代价是差量变成自己持有一份完整拷贝。CSI 把这件事打在 `-temp` 上（问题 30），不打正在 map 给虚拟机的那张。

**但 COW 不是池的开关。** 池里有 81 张 RBD 镜像：

```text
有父（会 COW）      66 张
没有父（链根）      15 张   ← 4 张模板底 + 5 套 db-data/redis-data（10 块）+ 1 块测试盘
```

只有有 `parent:` 的那 66 张才做 COW。链根本身是普通精简置备盘，不做任何复制。

StorageClass 里的 `imageFeatures: layering` 只是**允许**在这张图上做快照和克隆——没有这一位，`rbd clone` 直接报错。它不会让每张图都变成 COW，决定 COW 的是**这张图有没有父**。

### 问题 37：从 URL 导入完，为什么还不能直接当模板？

因为**导入得到的只是一块盘，不是一台能用的机器**。

盘里装着发行版的字节，但「能不能登进去」取决于镜像里的 sshd 配置和账号。而这两样东西，到你手上时都是关着的：

- **原厂云镜像一般不开密码认证。** 实测对一个**不存在**的用户名试 ssh，它列出来的可用方式只有 `publickey` 和 `gssapi-with-mic`，**没有 `password`**——对一个不存在的用户也只给这两种，说明密码认证是全局关的，不是某个账号被单独禁了。没配密钥就没人进得去。
- **管这套虚拟机的后端不注入凭据。** 它起虚拟机时只给一块克隆盘和一个网络接口（`masquerade`），没有 cloud-init、没有 secret、没有 sysprep。虚拟机里的账号只能来自盘本身。

所以中间这道工序省不掉：**在盘上开一次机，把登录方式配好，再关机。** 这一次改动就住在模板那一层里——前面看到的 404 MiB 就是它：

```text
链根的本层 2.0 GiB       导入来的原始镜像，登不进去
  → 模板的本层 404 MiB   在它上面开一次机，配好登录方式
  → 克隆的本层 104 MiB   虚拟机自己跑出来的
```

**那层改动多大，取决于你怎么改的。** 这集群上有两种现成样本：

| | 本层实占 | 怎么改的 |
| --- | --- | --- |
| 旧链的模板 | 8 MiB | 不启动系统，直接改盘里的文件 |
| 新链的模板 | 404 MiB | 启动一次系统，让它自己改 |

差 50 倍，差的是开机副产物：日志、初始化状态，以及跟着写进盘的机器标识和 SSH 主机密钥。两种都达到了目的。

（旧链那 8 MiB 装不下一次开机，所以「离线改」是根据体积反推的，不是直接观测到的。）

**改动不要写在链根上，先克隆一层。** 克隆是 COW，瞬间完成、0 字节，那几百 MiB 不管落在哪一层都一样大。差别是「还能不能回答链根是什么」：

- 链根脏了只能重新导入。定制化要试错，没有干净的重来点。试过两个静默失败：cloud-init 的网络接口必须声明 `ports: [{port: 22}]`，否则 ssh 模块不跑；`ssh_pwauth` 只开 `PasswordAuthentication`，不会开 `PermitRootLogin`，两头都要做。
- 每个环境、每种 `volumeMode` 都要各自一份模板（CSI 不能跨命名空间、也不能跨模式克隆）。第一台把底改了，后面几台就叠在第一台的口味上，链也往上堆。
- 现在能说「这块是原厂镜像的字节，那块 404 MiB 是我的改动」，就是因为两者分属两层。

Block 走同一套工序。同一份镜像、同一次开机改登录方式，Filesystem 那层 404 MiB，Block 那层 264 MiB——差的是两次开机写的量，不是模式本身。改完再克隆一台、**不带任何 cloud-init** 起起来，几十秒就能登进去，说明登录方式写在盘上，不是临时注入的。

起机改会把 hostname、machine-id、SSH 主机密钥固化进模板，之后所有克隆共用。

---

## 第七部分：开机时盘怎么到虚拟机里

### 问题 38：开机时谁把盘交给 QEMU？

建链（问题 30）没有虚拟机。RBD 镜像已经在 Ceph 里，哪台节点都没 map。下面这些操作发生在 **VirtualMachine 变成 running、virt-launcher Pod 往节点上放的时候**，每次开机都做一遍。

```text
PVC 已经 Bound
VirtualMachine running=true
  virt-controller 建 virt-launcher Pod，把 PVC 写进 Pod.spec.volumes
  调度到某节点
  容器还不存在。kubelet 调 CSI 节点插件：
    rbd map → /dev/rbdN
    Filesystem：挂上已有的 ext4（不再 mkfs），bind-mount 进 Pod
    Block：不 mkfs、不挂载，把设备节点映射进 Pod（MapPodDevice）
  PodReadyToStartContainers
  三个容器起。compute 里：
    virt-launcher 写出 libvirt XML
    Filesystem：<disk type='file'>   QEMU 打开 .../disk.img
    Block：     <disk type='block'>  QEMU 打开 /dev/pvcdisk，io='native'
  QEMU 对客户机模拟 virtio 盘 vda
  客户机内核自己 mount 分区。它碰不到 /dev/rbdN
```

实测 Filesystem：调度之后大约 7 秒到 `PodReadyToStartContainers`，这 7 秒就是 `rbd map` 加挂载。容器是这一秒才起的。Block 同一条时间线，kubelet 事件里是 `MapPodDevice` 而不是挂载。

PVC 是普通 Pod 卷，和别的应用挂 PVC 同一条路径。差别是容器里跑的是 hypervisor。客户机不是容器；被容器化的是 hypervisor。

这台 Pod 三个容器，不是三台虚拟机：

```text
compute             virt-launcher + libvirt + QEMU     打开 disk.img 或 /dev/pvcdisk
guest-console-log   收串口日志                          不碰盘
hook-sidecar        钩子                                不碰盘
```

客户机里写一个文件，走的是同一条路反过来：

```text
客户机 write()
  → 客户机内核写成对 vda 某扇区的写
  → QEMU pwrite()
       Filesystem：写进 disk.img → 宿主机 ext4 → /dev/rbdN
       Block：    写进 /dev/pvcdisk → /dev/rbdN          ← 少一跳
  → krbd 发给 OSD
  → 这 4 MiB 对象还在父层：OSD 先拷到本层（copy-up），再改
```

关机反过来：QEMU 退出 → Pod 删掉 → kubelet umount 或取消设备映射 → `rbd unmap`。PVC 和 RBD 镜像还在，只是暂时没挂在任何节点上。Filesystem 的 `disk.img` 不是这一步创建的，导入时就写好了，克隆跟着过来。Block 没有这个文件，raw 就是块设备本身。

---

## 附录：名词速查表

| 名词 | 一句话解释 |
| --- | --- |
| PV | PersistentVolume。集群级资源，代表一块真实存储 |
| PVC | PersistentVolumeClaim。命名空间级资源，对存储的需求声明 |
| StorageClass | 规定用哪个 provisioner、哪个池、怎么回收 |
| provisioner | StorageClass 里指定由哪个驱动创建 PV，通常是 CSI 驱动的名字 |
| 动态供给 | 按 PVC 的 StorageClass 现做 PV。现在默认 |
| 静态供给 | 管理员先建好 PV，用户再建 PVC 去配对 |
| dataSource | PVC 上的字段，声明「以某个已有 PVC 为源克隆」 |
| reclaimPolicy | 删 PVC 后 PV 怎么处置。`Delete` 连盘删，`Retain` 留着 |
| CSI | 容器存储接口。K8s 对接存储的标准插件 API |
| Controller 插件 | CSI 的建盘/克隆/扩容部分，以 Deployment 常驻 |
| Node 插件 | CSI 的挂盘/格式化部分，以 DaemonSet 运行在每台节点 |
| Rook | 在 K8s 上部署和管理 Ceph 的 operator |
| RADOS | Ceph 的底层分布式对象存储 |
| RBD | RADOS Block Device。Ceph 的块设备，一块虚拟硬盘 |
| CephFS | Ceph 的 POSIX 文件系统接口 |
| RGW | Ceph 的 S3 / Swift 对象接口 |
| object | RADOS 的最小存储单位。有名字的一块字节，RBD 默认切 4MiB |
| `rbd_default_order` | 决定 RBD 的对象大小。22 对应 4MiB |
| PG | Placement Group。把很多 object 归为一组，一起放置和恢复 |
| `pg_num` | 池里的 PG 总数。真正决定「每个 PG 多大」的参数 |
| CRUSH | 由 PG 和拓扑哈希出 OSD 列表的算法。不查中心表 |
| OSD | 一块盘的守护进程。存 object、做副本 |
| MON | 维护集群地图（哪些守护进程在运行、谁是主）。奇数个，构成法定人数 |
| MGR | 监控、仪表盘、autoscaler。不走数据面 |
| MDS | CephFS 的元数据服务。RBD 不需要 |
| `size` | 每 PG 几份完整数据。决定 PG 落在几个 OSD 上 |
| `min_size` | 低于几份就停止写入。和 `size` 不是一回事 |
| `up` / `in` | 进程在运行 / 参与数据分配。和 reweight 是两回事 |
| reweight | 给某个 OSD 的权重乘的系数，用于微调它分到多少数据 |
| `VAR` | `ceph osd df` 里某块盘相对集群均值的偏离倍数 |
| `active+clean` | PG 的健康终态。其它状态都值得看一眼 |
| `UP` / `ACTING` | PG 应有的副本位置 / 当前实际位置。不一致就是在迁移 |
| peering | 同一 PG 的副本之间协商状态的过程。按 PG 做，不按对象 |
| `chooseleaf host` | CRUSH 规则写法。先挑主机再挑盘，保证副本跨主机 |
| pool | 逻辑容器。副本数、PG 数、用哪些 OSD 都写在这里 |
| CDI | Containerized Data Importer。KubeVirt 子项目，负责把数据导入 PVC |
| DV | DataVolume。CDI 的自定义资源，描述一次数据导入作业 |
| `dataimportcron` | CDI 的定时导入，例如每月拉新版镜像 |
| `storageprofile` | CDI 记录每个 StorageClass 支持哪些克隆手段 |
| `csi-clone` | storageprofile 里的一种克隆策略，由 CSI 驱动执行 |
| importer | CDI 起的 Pod。负责从 HTTP/S3/registry 拉数据并转换格式 |
| qcow2 | QEMU 的磁盘镜像格式。CDI 导入时会转成 raw |
| KubeVirt | 在 K8s 里运行虚拟机的方案。虚拟机是一种自定义资源 |
| 虚拟盘大小 | URL 上下来的 qcow2 声明的盘容量。导入时 importer 按它校验。Filesystem 下 `disk.img` 就是这么长；Block 下客户机看到的是整块 RBD |
| 精简置备 | 声明容量和实际占用是两回事。RBD 默认如此 |
| COW | 写时复制。克隆只占用自己改动过的块 |
| `rbd clone` | RBD 基于快照的 COW 克隆 |
| VolumeImportSource | CDI 的自定义资源，把一个导入源包起来给 PVC 引用 |
| prime PVC | 导入期间真正被写入的临时盘，完成后回收 |
| scratch PVC | 压缩源导入时额外需要的临时盘 |
| `scratchSpaceStorageClass` | `CDIConfig` 里指定临时盘用哪个 storage class |
| `filesystemOverhead` | `CDIConfig` 里的比例，给文件系统元数据留空间，会放大 PVC 的 request |
| `volumeMode` | PVC 决定卷交给容器的形态。`Filesystem` 建文件系统再挂载，`Block` 直接给裸设备 |
| `claimPropertySets` | StorageProfile 里列的可用组合。CDI 不写 `volumeMode` 时按顺序挑第一条相符的 |
| `layering` | RBD 镜像的特性位。带这一位才允许 COW 克隆，由 StorageClass 的 `imageFeatures` 决定 |
| `fstype` | StorageClass 参数。`volumeMode: Filesystem` 时用它决定格式化哪种文件系统。Block 模式下 PV 的这个字段是空的 |
| 链根 | 一条 `parent` 链最底下那张图，自己没有父。它是一块完整镜像，克隆靠它才能读 |
| 定制化层 | 模板相对链根多出来的那一层。模板 = 链根 + 这层改动，所以两者只差几十到几百 MiB |
| `trash` 快照 | 克隆用的快照被放进 trash 命名空间，普通 `rbd snap ls` 看不到，`--all` 才看得到 |
| `op_features` | 镜像正在使用中的运营特性，例如 `clone-parent`、`snap-trash` |
| `flatten` | 把父层内容复制进子图，断开 `parent`，之后子图能独立存在 |
| `-temp` | CSI 克隆时插的中间镜像。带 `deep-flatten`，专门挨 flatten，不给虚拟机 map |
| `deep-flatten` | RBD 特性。有子图挂着也能 flatten。只有 `-temp` 开了，最终那张没有 |
| copy-up | 第一次写某个还在父层的 4 MiB 对象时，OSD 先拷到本层再改 |
| virt-launcher | KubeVirt 起的 Pod。里面跑 libvirt 和 QEMU。PVC 是它的普通卷 |
| `raw` | 未压缩的磁盘镜像，长度等于虚拟盘大小 |
