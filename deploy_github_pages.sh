#!/usr/bin/env bash
# 把 site/ 的内容推到仓库根，得到 https://miclshuialiyun.github.io/Slidewell/
#
# ⚠️ 仓库名必须叫 Slidewell —— GitHub Pages 路径大小写敏感，
#    写 slidewell 会得到另一个地址，且 AppBrand.siteRoot 与 ASC 四个 URL 字段全部失配。
# ⚠️ 推的是 site/ 的**内容**到仓库根，不是把整个项目推上去：
#    否则页面地址会变成 /Slidewell/site/index.html，与 AppBrand 里的链接不一致。
#
# 用法：
#   GITHUB_USER=miclshuialiyun GITHUB_TOKEN=ghp_xxxx ./deploy_github_pages.sh
#
# 令牌类型怎么选（2026-10-17 实测）：
#   classic + 只勾 `public_repo` 就够了 —— 站点仓库是公开的，
#   public_repo 能把写权限**限定在公开仓库**，比勾 `repo`（全部仓库读写）窄得多。
#   fine-grained 虽然更精细，但它的「Select repositories / Access」是自定义下拉，
#   浏览器自动化点不开（点 Access 无反应），所以走 classic 更省事。
#   GitHub 网页会在生成后**只显示一次**令牌：脚本读不到就说明该重开一次；
#   用截图 OCR 复制长串随机字符极易错一位（错一位 = 401 Bad credentials），
#   必须用页面上的 Copy 按钮 + pbpaste 取原文。
#
# 排错原则：任何一步失败都要把 GitHub 返回的**原文**打出来。
# 曾经用 curl -f 静默吞掉报错，令牌没权限时屏幕完全没有线索 —— 不可接受的诊断体验。

set -euo pipefail

REPO="Slidewell"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/site"

: "${GITHUB_USER:?需要设置 GITHUB_USER}"
: "${GITHUB_TOKEN:?需要设置 GITHUB_TOKEN（classic 令牌勾 repo；fine-grained 需 Contents: Read and write）}"

echo "==> 1/5 预检：源文件完整性与占位符"
for f in index.html privacy.html terms.html support.html; do
  [ -f "$SRC_DIR/$f" ] || { echo "缺少 $f"; exit 1; }
done
# ⚠️ 这里的 `|| true` 不是装饰：脚本开了 set -o pipefail，
#    而 grep 在「无匹配」时返回 1（符号链接/多文件时更常见），
#    没写 || true 的话整条管道状态就是 1，被 set -e 直接杀掉 —— 表现为
#    「脚本打印完 1/5 就静默退出、退出码还是 0（因为被 tail 吃了）」。
PLACEHOLDERS=$( { grep -rc '【待替换' "$SRC_DIR"/*.html 2>/dev/null || true; } | awk -F: '$2>0' | wc -l | tr -d ' ')
if [ "$PLACEHOLDERS" != "0" ]; then
  echo "!! 占位符未清零，共 $PLACEHOLDERS 处："
  grep -rno '【待替换：[^】]*】' "$SRC_DIR"/*.html
  echo "!! 继续部署会让审核员看到占位符。确认后请加 FORCE=1 重跑。"
  [ "${FORCE:-0}" = "1" ] || exit 1
fi

WORK=$(mktemp -d)
STASH=$(mktemp -d)
trap 'rm -rf "$WORK" "$STASH"' EXIT
cp -R "$SRC_DIR"/. "$WORK"/
cp -R "$SRC_DIR"/. "$STASH"/
cd "$WORK"

echo "==> 2/5 检查令牌与仓库写权限"
PROBE=$(curl -sS -o /tmp/gh_probe.json -w '%{http_code}' \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$GITHUB_USER/$REPO")
echo "    GET /repos/$GITHUB_USER/$REPO -> HTTP $PROBE"
if [ "$PROBE" = "404" ]; then
  echo "    仓库不存在，创建中…"
  CREATE=$(curl -sS -o /tmp/gh_create.json -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/user/repos" \
    -d "$(printf '{"name":"%s","public":true,"auto_init":false}' "$REPO")")
  echo "    POST /user/repos -> HTTP $CREATE"
  [ "$CREATE" = "201" ] || { echo "创建失败，GitHub 返回："; cat /tmp/gh_create.json; exit 1; }
elif [ "$PROBE" != "200" ]; then
  echo "    无法访问仓库，GitHub 返回："; cat /tmp/gh_probe.json; exit 1
fi
if [ "$PROBE" = "200" ]; then
  CAN_PUSH=$(/usr/bin/python3 -c "import json;print(json.load(open('/tmp/gh_probe.json'))['permissions'].get('push',False))")
  [ "$CAN_PUSH" = "True" ] || { echo "!! 令牌对该仓库没有 push 权限，请检查令牌 scope"; exit 1; }
fi

echo "==> 3/5 提交并推送"
git init -q
git checkout -q -b main 2>/dev/null || git checkout -q main
git config user.name  "${GITHUB_USER}"
git config user.email "${GITHUB_USER}@users.noreply.github.com"
REMOTE_URL="https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${REPO}.git"
git remote add origin "$REMOTE_URL" 2>/dev/null || git remote set-url origin "$REMOTE_URL"

# ⚠️ 网页建仓时勾了「Add a README」→ 远端已经有一个根提交。
#    此时把本地当成根提交去 push 会 non-fast-forward 失败。
#    正确做法：fetch 后 reset --hard 到 origin/main，让本次提交成为远端的**子提交**，
#    这样 README 等既有文件被保留；随后再用 STASH 把站点文件盖回去，
#    保证远端哪怕有同名文件也以 site/ 为准。
if git fetch -q origin main 2>/dev/null && git rev-parse --verify -q origin/main >/dev/null; then
  echo "    远端已有提交，基于 origin/main 追加（保留 README）"
  git reset -q --hard origin/main
  cp -R "$STASH"/. .
fi
git add -A
git commit -q -m "docs: Slidewell 独立站（中英双语）"
git push -q -u origin main || { echo "推送失败（常见原因：令牌无写权限 / 邮箱未验证 / 同名仓库属他人）"; exit 1; }

echo "==> 4/5 开启 GitHub Pages"
PAGES=$(curl -sS -o /tmp/gh_pages.json -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$GITHUB_USER/$REPO/pages" \
  -d '{"source":{"branch":"main","path":"/"}}')
echo "    POST /pages -> HTTP $PAGES"
if [ "$PAGES" != "201" ] && [ "$PAGES" != "204" ]; then
  echo "    自动开启失败（权限不足时常见）。请手动："
  echo "    Settings → Pages → Deploy from a branch → main / (root) → Save"
  cat /tmp/gh_pages.json
fi

echo "==> 5/5 校验四个 URL 可访问（最多等 60 秒）"
BASE="https://${GITHUB_USER}.github.io/${REPO}"
for i in $(seq 1 20); do
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/index.html")
  [ "$CODE" = "200" ] && break
  sleep 3
done
for p in index.html privacy.html terms.html support.html; do
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/$p")
  echo "    $BASE/$p -> HTTP $CODE"
done

echo
echo "完成后必须同步三处（漏一处就是 404 或口径不一致）："
echo "  1. App 内 Slidewell/Support/AppBrand.swift 的 siteRoot"
echo "  2. ASC 四个 URL 字段（营销 / 支持 / 隐私政策 / **许可协议**）"
echo "  3. 页脚营运主体名称与邮箱"
