---
title: "YARN 容器无法加载 Hadoop 类问题解决"
date: 2026-03-14
---

## 问题描述

HBase 2.5.11 提交 MapReduce 作业后，YARN 容器启动失败，错误信息：

```
Error: Could not find or load main class org.apache.hadoop.mapred.YarnChild
```

## 环境说明

- Hadoop: 3.3.6
- HBase: 2.5.11-hadoop3
- JDK: 8

## 根因分析

HBase 2.5.11 使用自带的 Hadoop 3.4.1 jar 提交作业，但 YARN 容器没有正确加载到 Hadoop 类。

YARN 容器启动命令中没有包含正确的 classpath：

```bash
# 错误的启动命令（缺少 classpath）
org.apache.hadoop.mapred.YarnChild 10.67.54.30 41097 ...
```

## 解决方案

在 `yarn-site.xml` 中添加 YARN 的 classpath 配置：

```xml
<property>
  <name>yarn.application.classpath</name>
  <value>$HADOOP_HOME/etc/hadoop,$HADOOP_HOME/share/hadoop/common/*,$HADOOP_HOME/share/hadoop/common/lib/*,$HADOOP_HOME/share/hadoop/hdfs/*,$HADOOP_HOME/share/hadoop/hdfs/lib/*,$HADOOP_HOME/share/hadoop/mapreduce/*,$HADOOP_HOME/share/hadoop/mapreduce/lib/*,$HADOOP_HOME/share/hadoop/yarn/*,$HADOOP_HOME/share/hadoop/yarn/lib/*</value>
</property>
```

配置后需要重启 YARN 集群。
