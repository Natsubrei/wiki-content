# Wiki 内容

Wiki 网站用的文章和小工具。这个仓库里没有网站程序。

`posts/` 是博客，`tools/` 是浏览器里跑的小工具。改文件后刷新即可。

## 文章

`posts/<slug>.md` → `/blog/<slug>`

```markdown
---
title: 标题
date: 2026-09-23
---

正文。
```

## 工具

`tools/<slug>.html` → `/tools/<slug>`

脚本只在访问者的浏览器里执行。

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
