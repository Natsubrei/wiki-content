---
title: "Hadoop HDFS-17779 问题排查与解决"
date: 2026-03-13
---

## 问题描述

在使用 HBase 2.5.11 的 `Import` 命令导入数据时，YARN 容器启动失败，错误信息如下：

```
/bin/bash: ADD_OPENS: No such file or directory
```

错误发生在 ApplicationMaster (AM) 容器启动阶段。

## 环境说明

- Hadoop: 3.3.6
- HBase: 2.5.11-hadoop3
- JDK: 8

## 根因分析

### 1. 版本兼容性问题

经过排查发现，**HBase 2.5.11 绑定的 Hadoop 版本是 3.4.1**，而不是用户集群使用的 3.3.6：

```
/opt/hbase-2.5.11-hadoop3/lib/hadoop-mapreduce-client-app-3.4.1.jar
/opt/hadoop-3.3.6/share/hadoop/mapreduce/hadoop-mapreduce-client-app-3.3.6.jar
```

### 2. ADD_OPENS 参数

Hadoop 3.4.1 为了支持 JDK 17，引入了 `--add-opens` JVM 参数：

```java
// Hadoop 3.4.1 YARNRunner.java
// JDK17 support: automatically add --add-opens=java.base/java.lang=ALL-UNNAMED
if (conf.getBoolean(MRJobConfig.MAPREDUCE_JVM_ADD_OPENS_JAVA_OPT,
        MRJobConfig.MAPREDUCE_JVM_ADD_OPENS_JAVA_OPT_DEFAULT)) {
    vargs.add(ApplicationConstants.JVM_ADD_OPENS_VAR);
}
```

该参数对应的常量是 `<ADD_OPENS>` 占位符，在 NodeManager 端会被替换为实际的 JDK 17 参数。

### 3. 版本不匹配

- HBase 客户端使用 Hadoop 3.4.1 jar 提交作业
- 客户端命令中添加了 `<ADD_OPENS>` 占位符
- 集群的 Hadoop 3.3.6 NodeManager 没有替换逻辑
- bash 直接执行 `<ADD_OPENS>` 导致错误

## 解决方案

### 方案：禁用 ADD_OPENS 参数

在 Hadoop 集群的 `mapred-site.xml` 中添加配置：

```xml
<property>
  <name>mapreduce.jvm.add-opens-as-default</name>
  <value>false</value>
</property>
```

配置后需要重启 YARN。

## 相关 Jira

- [HDFS-17779](https://issues.apache.org/jira/browse/HDFS-17779): Container fails to launch with error "ADD_OPENS: No such file or directory"
- [MAPREDUCE-7449](https://issues.apache.org/jira/browse/MAPREDUCE-7449): Add add-opens flag to container launch commands on JDK17 nodes

## 总结

问题的根本原因是 **HBase 2.5.11 使用了 Hadoop 3.4.1 的客户端库**，而集群运行的是 Hadoop 3.3.6。在 JDK 8 环境下，Hadoop 3.4.1 仍然会添加 JDK 17 特有的 `--add-opens` 参数，导致容器启动失败。

最简单的解决方案是在 mapred-site.xml 中禁用该参数。
