#!/usr/bin/env bash
set -euo pipefail
 
# ── 配置 ──────────────────────────────────────────────────────────────────────
TEMPLATE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
 
# ── 依赖检查 ──────────────────────────────────────────────────────────────────
for cmd in ogpk typst jq curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "error: $cmd not found in PATH" >&2
    exit 1
  fi
done
 
# ── 参数 ──────────────────────────────────────────────────────────────────────
URL="${1:?用法: $0 <url> [output.png]}"
OUTPUT="${2:-output/og-card.png}"
mkdir -p "$(dirname "$OUTPUT")"
 
# ── 1. 抓取 OG 元数据 ────────────────────────────────────────────────────────
echo "→ 抓取 OG 元数据: $URL"
META=$(ogpk -json "$URL")
 
# ── 2. 提取字段 ──────────────────────────────────────────────────────────────
title=$(echo "$META" | jq -r '.["og:title"] // empty')
desc=$(echo "$META" | jq -r '.["og:description"] // empty')
site_name=$(echo "$META" | jq -r '.["og:site_name"] // empty')
image_url=$(echo "$META" | jq -r '.["og:image:secure_url"] // .["og:image"] // empty')
og_url=$(echo "$META" | jq -r '.["og:url"] // empty')
if [ -z "$og_url" ] || [ "$og_url" = "null" ]; then
  og_url="$URL"
fi
 
# ── 3. 下载头像 ──────────────────────────────────────────────────────────────
avatar_path="null"
if [ -n "$image_url" ] && [ "$image_url" != "null" ]; then
  echo "→ 下载头像: $image_url"
  # 尝试下载，忽略失败
  if curl -sfL --max-time 10 -o "$WORK_DIR/avatar.jpg" "$image_url"; then
    avatar_path='"assets/avatar.jpg"'
    cp "$WORK_DIR/avatar.jpg" "$WORK_DIR/assets/avatar.jpg" 2>/dev/null || true
  else
    echo "  ⚠ 头像下载失败，跳过"
  fi
fi
 
# ── 4. 准备模板资源 ──────────────────────────────────────────────────────────
mkdir -p "$WORK_DIR/assets"
cp "$TEMPLATE_DIR/og-card.typ" "$WORK_DIR/"
 
# 如果头像下载成功，复制到 assets 目录
if [ "$avatar_path" != "null" ]; then
  cp "$WORK_DIR/avatar.jpg" "$WORK_DIR/assets/avatar.jpg"
fi
 
# ── 5. 构建 JSON 数据 ────────────────────────────────────────────────────────
DATA=$(jq -n \
  --arg title "$title" \
  --arg description "$desc" \
  --arg site_name "$site_name" \
  --arg url "$og_url" \
  --argjson avatar "$avatar_path" \
  '{
    title: $title,
    description: $description,
    site_name: $site_name,
    url: $url,
    avatar: $avatar
  }'
)
 
echo "→ 编译 Typst 模板..."
(cd "$WORK_DIR" && typst compile \
  --input "data=$DATA" \
  --format png \
  og-card.typ \
  output.png)
 
# ── 6. 输出 ──────────────────────────────────────────────────────────────────
cp "$WORK_DIR/output.png" "$OUTPUT"
echo "✓ 已生成: $OUTPUT"
