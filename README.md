# Wiki 内容

给 [Wiki](https://github.com/Natsubrei/wiki) 用的文章和工具。

Wiki 启动时通过 `POSTS_DIR`、`TOOLS_DIR` 指向这两个目录（Docker 则是把它们挂进容器）。请求页面时现场读取，所以：

1. 把本仓库放到 Wiki 能读到的路径（本机开发写进 `.env`，部署用 compose volumes）。
2. 增加或修改这里的文件。
3. 浏览器刷新对应网址。不必重建、重启 Wiki。

和 Wiki 并排放时，Wiki 的 compose 默认是：

```yaml
volumes:
  - ../wiki-content/posts:/app/posts
  - ../wiki-content/tools:/app/tools
```

本机开发在 Wiki 的 `.env` 里写：

```
POSTS_DIR=../wiki-content/posts
TOOLS_DIR=../wiki-content/tools
```

## 文章

`posts/<YYYY-MM-DD>-<slug>.md` 会出现在 Wiki 的 `/blog/<slug>`。文件名的日期要和 frontmatter 的 `date` 一致。

```markdown
---
title: 标题
date: 2026-09-23
---

正文。
```

## 工具

`tools/<slug>.html` 会出现在 Wiki 的 `/tools/<slug>`。脚本只在访问者浏览器里执行。

```html
---
title: 名称
description: 一句话
---
<div class="tool">...</div>
<script>
</script>
```

需要加宽版心时，在 frontmatter 里写 `wide: true`。

## 检查

`scripts/check.sh` 检查文件名日期、frontmatter 完整性、代码围栏成对，以及内部标识符。

每次提交前自动跑，clone 后启用一次：

```bash
git config core.hooksPath .githooks
```

不想用 hook 就直接跑 `scripts/check.sh`。

内部标识符的词表在仓库根的 `.denylist`，一行一个 `grep -E` 正则。它不进仓库（仓库是公开的），clone 后自己建；缺这个文件时那一项会跳过。
