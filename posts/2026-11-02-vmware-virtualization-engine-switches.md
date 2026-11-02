---
title: "VMware 的三个虚拟化开关：VT-x/EPT、IOMMU 与性能计数器"
date: 2026-11-02
---

## 第一部分：这三个开关在做什么

### 1. 它们在哪

VMware Workstation 里，选中一台虚拟机 →「编辑虚拟机设置」→「处理器」→「虚拟化引擎」，有三个复选框：

| 中文界面 | 英文界面 |
| --- | --- |
| 虚拟化 Intel VT-x/EPT 或 AMD-V/RVI | Virtualize Intel VT-x/EPT or AMD-V/RVI |
| 虚拟化 IOMMU（IO 内存管理单元） | Virtualize IOMMU (I/O memory management unit) |
| 虚拟化 CPU 性能计数器 | Virtualize CPU performance counters |

默认三项全关。

### 2. 共同点：把宿主机的硬件能力暴露给客户机

先分清两件事：

- **虚拟机本身已经在跑了**。CPU 陷入、内存翻译、设备模拟，VMware 自己就完成了，不需要这三个开关。
- **这三个开关决定的是：客户机能不能看见并使用宿主机 CPU 上的某项硬件能力**。

用一句话概括：

> 宿主机 CPU 上有某个硬件特性，要不要让它透传给虚拟机。

所以勾选它们不会让虚拟机变快，只会让客户机多出一种能力，并且通常更慢。

要理解每个开关，得先知道它对应的硬件是什么。

---

## 第二部分：宿主机 CPU 上的四项能力

### 3. VT-x / AMD-V：让敏感指令主动退出

**VT-x** 是 Intel 的 x86 硬件虚拟化扩展；AMD 的对应物叫 **AMD-V**（早期代号 SVM，Secure Virtual Machine）。

在没有它的年代，hypervisor（虚拟机监控器）只能用「陷入并模拟」的办法：客户机执行敏感指令时触发异常，hypervisor 捕获后模拟执行。问题在于 x86 有一批**敏感但非特权**的指令（比如读取某些状态），它们不触发异常，客户机可以直接读到宿主机的真实状态，隔离就漏了。这就是 x86 早期被认为「不适合虚拟化」的原因。

VT-x 的做法是给 CPU 增加两套操作模式：

```text
VMX root 模式      hypervisor 在这里运行，拥有完整权限
VMX non-root 模式  客户机在这里运行，敏感操作被硬件拦住
```

客户机执行到需要 hypervisor 处理的指令时，硬件自动做一次 **VM exit**（虚拟机退出），把控制权交给 hypervisor；处理完再 **VM entry**（虚拟机进入）返回客户机。整个过程由硬件完成，不再依赖软件扫描和打补丁。

控制信息放在 **VMCS**（Virtual Machine Control Structure，虚拟机控制结构）里，每个虚拟 CPU（vCPU）一份。它记录客户机的寄存器状态、宿主机的入口状态，以及一大批「哪些指令要触发 exit」的控制位。

**EPT**（Extended Page Tables，扩展页表）是同一套扩展里的另一项能力，下一节单独说。

### 4. EPT / RVI：第二段地址翻译

一台普通机器只有一段地址翻译：

```text
虚拟地址 ──[页表]──▶ 物理地址
```

虚拟机里变成两段：

```text
客户机虚拟地址 ──[客户机页表]──▶ 客户机物理地址 ──[EPT]──▶ 宿主机物理地址
```

客户机以为自己有一块从 0 开始的连续物理内存，那只是「客户机物理地址」。真正落到内存条上，还要再翻译一次。

没有 EPT 时，hypervisor 只能用**影子页表**（shadow page table）在软件里模拟这层映射：客户机每次改页表，hypervisor 都要拦截并同步一份影子表，开销很大。

有了 EPT，第二段翻译由 MMU（Memory Management Unit，内存管理单元）硬件一次走完，客户机改自己的页表不再需要 hypervisor 介入。

AMD 的同类技术叫 **NPT**（Nested Page Tables，嵌套页表），市场名叫 **RVI**（Rapid Virtualization Indexing，快速虚拟化索引）。这就是开关名字里「EPT 或 RVI」的来历。

### 5. IOMMU：给设备也配一套页表

**IOMMU** = I/O Memory Management Unit，I/O 内存管理单元。Intel 的实现叫 **VT-d**，AMD 的叫 **AMD-Vi**。

普通情况下，网卡、GPU 这类设备做 **DMA**（Direct Memory Access，直接内存访问）时直接读写物理内存，**完全绕过 CPU 的页表**。这既是性能来源，也是隔离漏洞：一个设备可以写到它本不该碰的内存。

IOMMU 的作用是给设备也配一套页表，让 DMA 请求先经过地址翻译和权限检查：

```text
设备发出的 DMA 地址 ──[IOMMU 页表]──▶ 宿主机物理地址
```

它在虚拟化里的用途是设备直通：把一块物理设备交给某台虚拟机独占，同时保证这台机器只能访问分配给它的内存区域。

### 6. PMU：性能监控单元

**PMU**（Performance Monitoring Unit，性能监控单元）是 CPU 里的一组硬件计数器，能统计「退休指令数」「缓存未命中」「分支预测失败」等事件。

软件通过一组 **MSR**（Model-Specific Register，模型特定寄存器）访问它，比如 `IA32_PERFEVTSELx` 配置要统计的事件，`IA32_PMCx` 读取计数值。Linux 上的 `perf`、Intel 的 VTune 都建立在它之上。

---

## 第三部分：逐个开关

### 7. Virtualize Intel VT-x/EPT or AMD-V/RVI

**透传的东西**：CPU 的硬件虚拟化扩展（VMX 或 SVM），以及配套的二级地址翻译。

**勾上之后**：客户机里的 CPUID 指令会报告「本机支持 VT-x/EPT」。客户机因此可以**自己再当一次 hypervisor**，这就是**嵌套虚拟化**（nested virtualization）。

典型场景：

- 在虚拟机里跑 KVM、Hyper-V、VirtualBox
- 跑 Docker Desktop（它的底层是一台 Linux 虚拟机）
- 跑 WSL2（Windows Subsystem for Linux 2，底层同样用 Hyper-V 虚拟机）
- 跑 Android 模拟器

三层的关系是：

```text
L0  物理机上的 hypervisor（VMware）
L1  客户机里的 hypervisor（比如 KVM）
L2  L1 里跑的虚拟机
```

**代价**：每次地址翻译要穿两层页表；VMCS 本身也需要被虚拟化（硬件提供 VMCS shadowing 减少 exit，但消不掉全部开销）；VM exit 更贵。整体性能明显下降，内存也要多留。

**一个常见的坑**：如果宿主机是 Windows，并且已经启用了 Hyper-V、WSL2 或「内存完整性」（VBS，Virtualization-Based Security，基于虚拟化的安全），VT-x 已经被 Windows 自己的 hypervisor 占用。此时 VMware Workstation（15.5.5 之后）会改为运行在 **WHP**（Windows Hypervisor Platform，Windows 虚拟机监控程序平台）之上，这个选项通常变灰或失效，性能也下降。要恢复纯 VMware 的虚拟化路径，需要在 Windows 功能里关掉 Hyper-V 相关项并重启。

### 8. Virtualize IOMMU

**透传的东西**：I/O 地址翻译硬件（VT-d 或 AMD-Vi）的虚拟版本。

**为什么客户机需要它**：客户机内核可能想在自己内部做 DMA 保护。比如 Windows 的「内核 DMA 保护」，或者 Linux 客户机加 `intel_iommu=on` 启动参数。这些功能要求它能看见一块 IOMMU 硬件。勾选后，VMware 给它模拟一个。

**实际用得上的场景很窄**：

- 嵌套虚拟化里，L1 想给 L2 做设备直通
- 客户机想启用 DMA 重映射做安全加固

注意 VMware Workstation **本身不支持 PCI 设备直通**，那是 ESXi 的功能。所以这个选项在 Workstation 里更多是「让客户机别报缺少 IOMMU」，而不是真的把一块网卡交给虚拟机。

**代价**：多一层地址翻译，DMA 路径变长。

### 9. Virtualize CPU performance counters

**透传的东西**：PMU 及其 MSR。

**默认不虚拟化的原因有两个**：

1. **开销**。客户机访问这些 MSR 会触发 VM exit，由 hypervisor 模拟后返回，每次都不便宜。性能剖析工具调用极频繁，累积开销可观。
2. **安全**。PMU 是高精度的微架构侧信道。已有研究证明，把 vPMU 暴露给客户机会形成跨虚拟机的隐蔽信道，能以可观带宽传递信息。所以公有云普遍关闭 vPMU。

**勾上之后**：Linux 客户机里 `perf stat` 能出数据，Windows 上的性能剖析工具也能采样。做性能分析、研究 CPU 微架构行为（比如测缓存时序、做侧信道实验）时需要它。

---

## 第四部分：怎么选，以及怎么排错

### 10. 决策表

| 你想做的事 | 需要的开关 |
| --- | --- |
| 在虚拟机里跑 Docker Desktop、WSL2、安卓模拟器、另一个虚拟机 | 第 1 项 |
| 客户机里要启用 DMA 保护，或做设备直通 | 第 1 项 + 第 2 项 |
| 在虚拟机里跑 `perf`、做性能剖析或侧信道实验 | 第 3 项 |
| 只是装个 Linux 学课程内容、跑普通服务 | 三项全不用开 |

### 11. 选项灰掉或嵌套失败，先查什么

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 第 1 项灰掉 | 宿主机 Windows 已启用 Hyper-V / WSL2 / VBS | 关闭这些功能并重启，或接受跑在 WHP 上 |
| 虚拟机里没有 `/dev/kvm` | 宿主机没开嵌套虚拟化（云主机常见） | 在云控制台开启嵌套，或换物理机 |
| 客户机里 `perf` 报无权限或无数据 | vPMU 未暴露 | 勾第 3 项，并检查客户机 `perf_event_paranoid` |
| 客户机里 DMA 保护开关不可用 | 虚拟 IOMMU 未暴露 | 勾第 2 项 |

其中「虚拟机里没有 `/dev/kvm`」值得单独说：这不是 KVM 装坏了，而是宿主机没有把虚拟化能力暴露给这台客户机。家用电脑和多数云主机默认都不开。

### 12. 四个容易混淆的地方

**一、这三个开关不是「开启虚拟化」。** 虚拟化已经在运行。它们只决定客户机能否看见宿主机的某项硬件能力。

**二、VT-x 和 EPT 是两项能力，不是一个。** VT-x 管陷入与 VMCS，EPT 管第二段地址翻译。VMware 把它们放在同一个开关里，因为实际使用中几乎总是一起需要。

**三、IOMMU 不是「IO 内存观看单元」。** 全称是 I/O Memory Management Unit，I/O 内存管理单元。它做地址翻译和权限检查，不做「观看」。

**四、勾选不会提升性能。** 三项都是「给客户机更多能力」，代价是更多的 exit、更长的翻译路径、更大的攻击面。没有需求就不要勾。

---

## 一句话总结

三个开关对应宿主机 CPU 的四项硬件能力：VT-x/AMD-V 提供陷入与两套特权级，EPT/RVI 提供第二段地址翻译，IOMMU/VT-d 给设备配页表，PMU 提供性能计数器。VMware 默认不把它们透传给客户机，因为每一项都要付性能和安全的代价；只有客户机确实需要「自己再当 hypervisor」「自己管 DMA」「自己跑 perf」时才打开。
