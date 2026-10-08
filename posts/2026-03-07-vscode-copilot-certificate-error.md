---
title: "VS Code Copilot：certificate is not yet valid"
date: 2026-03-07
---

## 问题描述

在使用 VS Code Copilot 扩展时，出现以下错误：

```
Error: certificate is not yet valid
```

具体表现：
- Copilot 无法加载模型列表
- Copilot 无法加载远程代理
- 所有涉及 HTTPS 的网络请求都失败
- 错误堆栈显示 TLS 连接失败

```
2026-03-07 06:17:48.916 [error] TypeError: fetch failed
  Error: certificate is not yet valid
      at TLSSocket.onConnectSecure (node:_tls_wrap:1697:34)
```

## 根本原因

**系统时钟未同步** - 这是问题的核心。

SSL/TLS 证书都有一个有效期，包含开始时间（notBefore）和结束时间（notAfter）。当系统时间不在证书的有效期范围内时，就会导致证书验证失败。

"certificate is not yet valid" 表示系统时间早于证书的开始生效时间。

### 现象分析

```bash
$ timedatectl status
Local time: Sat 2026-03-07 06:21:09 CST
Universal time: Fri 2026-03-06 22:21:09 UTC
RTC time: Mon 2026-03-09 01:33:39    ← 硬件时钟时间
System clock synchronized: no        ← 系统时钟未同步
```

可以看到：
- 系统时钟显示 3月7日
- 硬件时钟（RTC）显示 3月9日
- NTP 服务虽然 active 但实际未同步成功

## 解决方案

### 步骤 1：启用网络代理（如需要）

如果需要通过代理访问外网：

```bash
# 在 ~/.bashrc 中配置的代理
export http_proxy=http://192.168.59.1:7890
export https_proxy=http://192.168.59.1:7890
```

### 步骤 2：同步系统时间

通过可访问的网络服务获取正确时间：

```bash
# 从 Google 获取时间（需要代理）
date -s "$(date -d "$(curl -sI https://www.google.com | grep -i '^date:' | sed 's/date: //gi)')"
```

### 步骤 3：同步硬件时钟

将系统时间同步到硬件时钟：

```bash
hwclock --systohc
```

### 步骤 4：验证

```bash
$ timedatectl status
               Local time: Mon 2026-03-09 09:38:57 CST
           Universal time: Mon 2026-03-09 01:38:57 UTC
                 RTC time: Mon 2026-03-09 01:38:57
System clock synchronized: no
              NTP service: active
          RTC in local TZ: no
```

现在系统时钟和 RTC 已同步。

### 步骤 5：重载 VS Code

在 VS Code 中按 `Ctrl+Shift+P`，输入 `Reload Window` 并回车，让 Copilot 扩展重新加载。

## 预防措施

### 1. 配置 NTP 自动同步

```bash
timedatectl set-ntp true
```

如果 NTP 服务有问题，可以检查日志：

```bash
journalctl -u systemd-timesyncd -f
```

### 2. 定期检查时间同步状态

```bash
timedatectl status
```

### 3. 确保防火墙允许 NTP 端口

NTP 使用 UDP 123 端口，确保防火墙允许：

```bash
firewall-cmd --add-service=ntp --permanent
firewall-cmd --reload
```

## 常见相关问题

### Q: NTP 服务显示 active 但时间仍未同步？

A: 可能原因：
- 网络连接问题（检查能否访问 NTP 服务器）
- NTP 服务器不可达（尝试更换服务器）
- 防火墙阻断了 NTP 流量

### Q: 证书验证失败的常见原因有哪些？

A:
1. **系统时间错误** - 最常见原因
2. 证书确实已过期或尚未生效
3. 系统证书存储损坏
4. 中间证书缺失

### Q: 如何调试证书问题？

A:
```bash
# 检查证书详细信息
openssl s_client -connect example.com:443 -showcerts

# 检查系统时间
date

# 检查时区
timedatectl
```

## 总结

"certificate is not yet valid" 错误看似复杂，但 90% 的情况都是系统时钟同步问题引起的。遇到此类问题时，首先检查：

1. `date` - 当前时间是否正确
2. `timedatectl status` - 时钟同步状态
3. 网络连接和代理配置

快速修复方法：从可靠的网络服务获取时间并同步系统时钟。

---

**环境**: Linux 6.6.0-140.0.0.123.oe2403sp3.x86_64 (OpenEuler)
