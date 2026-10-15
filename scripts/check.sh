#!/usr/bin/env bash
# 检查 posts/ 与 tools/ 的发布契约。这个仓库没有 CI，所以靠 .githooks/pre-commit 调它，
# 也可以直接跑：scripts/check.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

fail=0
note() { printf '  x %s\n' "$1"; fail=1; }
info() { printf '  %s\n' "$1"; }

echo "posts/"
for f in posts/*.md; do
  [ -e "$f" ] || continue
  base=$(basename "$f" .md)

  case "$base" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-?*) ;;
    *) note "$f: 文件名要形如 YYYY-MM-DD-slug.md"; continue ;;
  esac

  fdate=${base:0:10}
  head -1 "$f" | grep -qx -- '---' || { note "$f: 第一行不是 frontmatter 开头"; continue; }

  fm=$(sed -n '2,/^---$/p' "$f")
  echo "$fm" | grep -q '^title:' || note "$f: frontmatter 缺 title"
  echo "$fm" | grep -q '^date:'  || note "$f: frontmatter 缺 date"

  ddate=$(echo "$fm" | sed -n 's/^date:[[:space:]]*//p' | head -1 | tr -d '"'"'")
  [ "$ddate" = "$fdate" ] || note "$f: date $ddate 与文件名 $fdate 不一致"

  n=$(grep -c '^```' "$f")
  [ $((n % 2)) -eq 0 ] || note "$f: 代码围栏 $n 个，不成对"
done

echo "tools/"
for f in tools/*.html; do
  [ -e "$f" ] || continue
  head -1 "$f" | grep -qx -- '---' || { note "$f: 第一行不是 frontmatter 开头"; continue; }
  fm=$(sed -n '2,/^---$/p' "$f")
  echo "$fm" | grep -q '^title:'       || note "$f: frontmatter 缺 title"
  echo "$fm" | grep -q '^description:' || note "$f: frontmatter 缺 description"
done

echo "内部标识符"
# 词表本身不进仓库（仓库是公开的）。放仓库根的 .denylist，一行一个 grep -E 正则，
# '#' 开头是注释。文件不存在时只提示，不算失败。
dl=.denylist
if [ -f "$dl" ]; then
  while IFS= read -r p; do
    case "$p" in '' | '#'*) continue ;; esac
    hit=$(grep -rIn -iE "$p" posts tools README.md 2>/dev/null)
    if [ -n "$hit" ]; then
      note "$p"
      echo "$hit" | sed 's/^/      /'
    fi
  done < "$dl"
else
  info "没有 $dl，跳过。放进内部标识符的正则，一行一个。"
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "检查未通过。"
  exit 1
fi
echo
echo "全部通过。"
