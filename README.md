# Wiki 内容

给 [Wiki](https://github.com/Natsubrei/wiki) 用的文章和小工具。网站程序在那个仓库，这里只有文件。

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

`posts/<slug>.md` 会出现在 Wiki 的 `/blog/<slug>`。

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
