---
title: "用 CDI 从 URL 导入系统盘：PVC、PV 与 Ceph 概念梳理"
date: 2026-10-15
---

## 引子

我在一个 Kubernetes 集群上给内核调试实验铺存储。实验要起 KubeVirt 虚拟机，每台虚拟机需要一块 42Gi 的系统盘，上面预装好内核和工具链。

这块盘以前是自己装的：用 `virt-install` 起一台虚拟机，运行一遍发行版安装程序，装好内核和工具链，再把产出的磁盘镜像导入集群。装一次要等一次，基础镜像改一下就重做一遍。

最近才知道 CDI 可以直接把远端镜像导入成 PVC：写一个 DataVolume，给个 URL，下载、格式转换、写盘都由它做。

照着模板能写出来，但每个字段在做什么，我说不清：

```yaml
spec:
  storageClassName: ceph-block
  dataSource:
    name: vm-template
    kind: PersistentVolumeClaim
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 42Gi
```

能创建成功，但我不清楚每一行在操作什么：`dataSource` 是谁在实现，`ceph-block` 由谁执行，磁盘到底落在哪几台机器上。

本文把这条链上的概念逐个拆开，从 Kubernetes 的声明一路问到 Ceph 底层的字节。

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
用户：我要 42Gi、ReadWriteOnce、ceph-block
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
  resources.requests.storage: 42Gi    # 要多大
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
新 PV     克隆出来的 42Gi RBD
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

要理解为什么这么设计，先看问题：42Gi 的虚拟机盘，怎么放到二十几块物理盘上，掉一块还能用？

两种极端都不行：

- **整盘当一份**：没法并行读写，恢复时要把整块重新复制一遍，热点集中在一块盘上。
- **每 4KB 当一份**：对象数和元数据量都不可接受。42Gi 会切成 1100 万个对象，光元数据就足以成为瓶颈。

所以拆三层，各管一件事：

```text
你看见的     42Gi 硬盘（RBD 镜像）
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
对象数        53.31k
池逻辑数据    53.31k × 4 MiB ≈ 208 GiB    ← ceph df 报 206 GiB ✓
pg_num        128

每 PG 容量    ≈ 206 GiB / 128 ≈ 1.6 GiB
每 PG 对象数  ≈ 53310 / 128   ≈ 416 个
每 PG 裸占    ≈ 1.6 × 3       ≈ 4.8 GiB   （3 副本）
```

所以真正需要调的是 **`pg_num`**，不是「PG 大小」。想让每 PG 降到 1 GiB，就把 `pg_num` 翻倍。

两个提醒：

- 1.6 GiB 是**均值**。对象按名字哈希进 PG，分布不均匀，有的 PG 装四五百个对象，有的一百多。
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

**走的是 PVC，CDI 没参与。**

三条证据：

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

两者是替代关系，不是叠加。**要克隆就用 `dataSource` 让 CSI 干；要从外部拉镜像才需要 DV/CDI。**

时间线也支持这个结论：CDI 是两天前刚装的，而模板 PVC 是 33 天和 126 天前建的。那些克隆不可能是 CDI 做的。

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
    objects: 53.31k objects, 207 GiB
    usage:   655 GiB used, 2.4 TiB / 3 TiB avail
    pgs:     129 active+clean
```

先看 `health`，再看 `pgs` 那行是不是全 `active+clean`。

一个运维习惯：**`ceph -s` 里的 pg 状态比 `ceph health` 更早暴露问题**。`active+clean` 是健康终态；出现 `degraded`、`peering`、`remapped`、`undersized` 都说明有副本没到位。

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
ID  CLASS  WEIGHT  REWEIGHT  SIZE     RAW USE  DATA     OMAP     META     AVAIL    %USE   VAR   PGS
 1    hdd  0.12500  1.00000  128 GiB   30 GiB   28 GiB   30 KiB  1.8 GiB   98 GiB  23.19  1.09   17
11    hdd  0.12500  1.00000  128 GiB   34 GiB   34 GiB   35 KiB  849 MiB   94 GiB  26.89  1.26   21
...
                    TOTAL    3 TiB   655 GiB  619 GiB  840 KiB   36 GiB  2.4 TiB  21.31
MIN/MAX VAR: 0.80/1.30  STDDEV: 3.60
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

那条公式服务的是**大池、高并发、需要把负载摊到足够多 PG 上**的场景。这里的池只有 206 GiB、5 万多个对象，128 个 PG 已经让每个 OSD 分到 16 个，分布也均衡（`VAR` 最大 1.30）。

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
3. 新 PVC 的容量不小于模板（精确到字节的规则见问题 32）

第 1 条是第 8 问里没提、但实际会限制用法的条件。它解释了为什么每个环境命名空间里都各存一份 `vm-template`：

```text
env-dev    vm-template   42Gi  Bound
env-os     vm-template   42Gi  Bound
env-test   vm-template   42Gi  Bound
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

---

## 第六部分：导入与克隆，尺寸怎么定

前面讲了 DV 和 CSI 克隆分别是什么。这一部分回答四个具体问题：导入过程中发生了什么、克隆是不是真的省空间、那堆看起来都叫「大小」的数字各自是什么、以及什么尺寸才够用。

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

### 问题 30：CSI 克隆是全量复制还是 COW？

**是 COW。** 实现方式是 RBD 快照加 `rbd clone`。

证据取自一个正在被十几个克隆共享的模板：

```text
rbd info  <模板>
  op_features: clone-parent, clone-child, snap-trash
  parent: vm-pool/csi-vol-<...>-temp@<快照>

rbd children <模板>
  17 个子卷

rbd du -p vm-pool
  csi-vol-<模板>            声明 42 GiB   实占 8 MiB
  csi-vol-<克隆>-temp       声明 42 GiB   实占 0 B
  csi-vol-<克隆>            声明 42 GiB   实占 1.4 GiB
```

**每个逻辑克隆对应两块 RBD 镜像。** 控制器分两步：先把源快照 COW 克隆成一块临时镜像，再从临时镜像的快照 COW 克隆出目标镜像。

```text
csi-vol-<模板>                声明 42Gi   实占 8 MiB
  └─ csi-vol-<克隆>-temp      声明 42Gi   实占 0 B
       └─ csi-vol-<克隆>      声明 42Gi   实占 1.4 GiB   ← 虚拟机写出来的部分
```

三个后果：

- **省空间是真的。** 克隆只付自己写出来的那些块。上面那块虚拟机用了 1.4 GiB，不是 42 GiB。整个池合计：声明 2.5 TiB，实占 208 GiB。
- **模板不能随便删。** 父快照被保护，模板带着十几个活子卷时删不掉，要先删子卷或者 flatten。模板和克隆之间有依赖。
- **COW 与 volumeMode 无关。** 它是 RBD 层的性质，Filesystem 和 Block 两种模式都省空间。

顺带把一个容易混的印象分清：**从 URL 导入**是真的把字节写进去，**`dataSource` 克隆**是 COW。两者是不同的操作，开销不能放在一起比。

### 问题 31：那些「大小」分别是什么？

一块盘从 URL 到虚拟机，中间经过六个不同的数，名字都像「大小」，来源完全不同。

| 名称 | 含义 | 从哪来 | 谁决定 |
| --- | --- | --- | --- |
| 压缩包 | 下载体积 | HTTP `Content-Length` | 发布方的压缩 |
| 虚拟盘大小 | 客户机看到的盘容量 | qcow2 头部偏移 `0x18` 的 8 字节 | 镜像制作者 |
| 镜像实占 | 镜像里真正写过的块 | 精简置备 | 镜像内容 |
| PVC request | 实际提交的存储申请 | DV 请求 × `(1 + filesystemOverhead)` | 集群配置 |
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

读出来的 `0x0000000A00000000` 是 `42,949,672,960`，即 40 GiB。**这个数才是「盘有多大」。**

压缩包小、虚拟盘大，不矛盾：前者是数据被压缩后的体积，后者是客户机能用的容量。实占介于两者之间，取决于镜像是稀疏的还是带着真实数据。

### 问题 32：什么尺寸能导入，什么尺寸能克隆？

两条独立的不等式。**导入看的和克隆看的是同一个数：PVC 的 request。**

导入阶段，importer 会拿源镜像的虚拟大小和目标的 request 比。请求明显过小时它会把两个数都报出来：

```text
virtual image size 42949672960 is larger than the reported available storage 1138166334.
A larger PVC is required
```

- `42949672960` 就是问题 31 里那个虚拟盘大小，40 GiB
- `1138166334` 是 PVC 的 **request**，等于 `1Gi × 1.06`。不是那块 PVC 的 capacity，它的 capacity 是 2Gi

于是两条规则：

```text
导入   用户请求 × (1 + filesystemOverhead) ≥ 虚拟盘大小
克隆   克隆请求 ≥ 用户请求 × (1 + filesystemOverhead)
```

代入一组实测（虚拟盘 40 GiB，overhead 0.06）：

| 用户请求 | PVC request | PV capacity | 能导入 | 克隆请求 42Gi 够吗 |
| --- | --- | --- | --- | --- |
| 1Gi | 1.06 GiB | 2Gi | 否 | — |
| 39Gi | 41.34 GiB | 42Gi | 是 | 够 |
| 42Gi | 44.52 GiB | 45Gi | 是 | 不够，要 45Gi |

**那 6% 只影响这两个数，不影响实占。** overhead 让 request 变大，PV 向上取整也跟着变大，但 RBD 是精简置备，多出来的容量不占空间。问题 30 里的池合计就是证据：声明 2.5 TiB，实占 208 GiB。

所以想保住某个容量时，有三条路可走：

1. **顺着 overhead 走。** 请求 42Gi，接受 45Gi 的 PV，把克隆尺寸也调到 45Gi。
2. **反向凑。** 请求 39Gi，request 是 41.34 GiB，PV 落在 42Gi，克隆 42Gi 就够。代价是引入一个只看 overhead 才说得通的数字。
3. **把 overhead 置 0。** 改 `CDIConfig` 里这个 storage class 的 `filesystemOverhead`，请求多少就是多少。

第 3 条影响该 storage class 上此后所有的 DV 导入，动手前要清楚这一点。

**overhead 不是一个多余的设计。** 文件系统本身要占一部分空间放元数据，声明 42Gi 的盘实际装不下 42Gi 的文件。CDI 用这个比例保证导入的文件放得进去。

最后把这个结论接回引子：那份清单写的是 `storage: 42Gi`。按上面的规则，它会建成 45Gi 的 PV，克隆尺寸也得跟着调到 45Gi。

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
| 虚拟盘大小 | qcow2 头部声明的盘容量。客户机看到的就是它 |
| 精简置备 | 声明容量和实际占用是两回事。RBD 默认如此 |
| COW | 写时复制。克隆只占用自己改动过的块 |
| `rbd clone` | RBD 基于快照的 COW 克隆 |
| VolumeImportSource | CDI 的自定义资源，把一个导入源包起来给 PVC 引用 |
| prime PVC | 导入期间真正被写入的临时盘，完成后回收 |
| scratch PVC | 压缩源导入时额外需要的临时盘 |
| `scratchSpaceStorageClass` | `CDIConfig` 里指定临时盘用哪个 storage class |
| `filesystemOverhead` | `CDIConfig` 里的比例，给文件系统元数据留空间，会放大 PVC 的 request |
