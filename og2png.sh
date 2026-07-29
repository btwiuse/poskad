#!/usr/bin/env bash
set -euo pipefail
 
# ── 配置 ──────────────────────────────────────────────────────────────────────
TEMPLATE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
 
# ── 依赖检查 ──────────────────────────────────────────────────────────────────
for cmd in ogpk typst jq curl npx magick fc-match fc-list; do
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
image_width=$(echo "$META" | jq -r '.["og:image:width"] // empty')
image_height=$(echo "$META" | jq -r '.["og:image:height"] // empty')
og_url=$(echo "$META" | jq -r '.["og:url"] // empty')
if [ -z "$og_url" ] || [ "$og_url" = "null" ]; then
  og_url="$URL"
fi

# 将 description 里的 t.co 短链替换成最终地址，便于图片阅读。PNG 无法承载
# 可点击的超链接，故使用最终地址作为可见文本；http:// 前缀按约定移除。
expand_tco_links() {
  local remaining="$1"
  local result=""
  local short_url prefix resolved display_url

  while [[ "$remaining" =~ (https?://t\.co/[[:alnum:]_-]+) ]]; do
    short_url="${BASH_REMATCH[1]}"
    prefix="${remaining%%"$short_url"*}"
    remaining="${remaining#*"$short_url"}"

    resolved=$(curl -Ls --max-time 15 -o /dev/null -w '%{url_effective}' "$short_url" || true)
    if [[ "$resolved" =~ ^https?:// ]]; then
      # 纯 HTTPS 域名（如 https://heart.blue/）显示为更简洁的 heart.blue；
      # 带路径、查询或片段的 HTTPS 链接仍完整保留。
      if [[ "$resolved" =~ ^https://([^/?#]+)/?$ ]]; then
        display_url="${BASH_REMATCH[1]}"
      else
        display_url="${resolved#http://}"
      fi
      result+="${prefix}${display_url}"
    else
      # 解析失败时不丢失原有短链。
      result+="${prefix}${short_url}"
    fi
  done

  printf '%s' "${result}${remaining}"
}

if [[ "$desc" == *"t.co/"* ]]; then
  echo "→ 展开 description 中的 t.co 链接..."
  desc=$(expand_tco_links "$desc")
fi

# X 的 OG 标题通常是「显示名 (@用户名) on X」。拆开后更像原生帖子卡片；
# 其他站点仍保留完整标题作为作者行。
author="$title"
handle=""
if [[ "$title" =~ ^(.*)[[:space:]]\(@([^\)]+)\)[[:space:]]on[[:space:]]X$ ]]; then
  author="${BASH_REMATCH[1]}"
  handle="@${BASH_REMATCH[2]}"
fi

# 根据运行环境选择已安装字体：本机使用 macOS 字体，容器使用 Noto。
has_font() {
  # 不使用 grep -q：set -o pipefail 下它会提前关闭管道并让 fc-list 收到 SIGPIPE。
  fc-list --format='%{family}\n' | tr ',' '\n' | grep -Fx "$1" >/dev/null
}
if has_font "Helvetica Neue"; then
  font_sans="Helvetica Neue"
  font_cjk="Hiragino Sans GB"
  font_emoji="Apple Color Emoji"
else
  font_sans="Noto Sans CJK SC"
  font_cjk="Noto Sans CJK SC"
  font_emoji="Noto Color Emoji"
fi
font_math="STIX Two Math"

# ── 3. 准备模板资源 ──────────────────────────────────────────────────────────
mkdir -p "$WORK_DIR/assets"

# ── 4. 下载头像与帖子配图 ────────────────────────────────────────────────────
# X 对无图帖子通常把 400×400 的 profile image 放在 og:image。若尺寸并非
# 400×400 且 URL 也不是常见的 200x200 头像，则把它视为帖子配图，头像改由
# unavatar 根据从 og:title 拆出的 @用户名获取。
avatar_path="null"
post_image_path="null"
if [ -n "$image_url" ] && [ "$image_url" != "null" ]; then
  if [[ -n "$handle" && ( "$image_width" != "400" || "$image_height" != "400" ) && "$image_url" != *_200x200.jpg ]]; then
    avatar_url="https://unavatar.io/x/${handle#@}"
    echo "→ 下载头像: $avatar_url"
    if curl -sfL --max-time 15 -o "$WORK_DIR/avatar.jpg" "$avatar_url"; then
      avatar_path='"assets/avatar.jpg"'
    else
      echo "  ⚠ unavatar 头像下载失败，跳过"
    fi

    echo "→ 下载帖子配图: $image_url"
    if curl -sfL --max-time 20 -o "$WORK_DIR/post-image.jpg" "$image_url"; then
      post_image_path='"assets/post-image.jpg"'
    else
      echo "  ⚠ 帖子配图下载失败，跳过"
    fi
  else
    echo "→ 下载头像: $image_url"
    if curl -sfL --max-time 10 -o "$WORK_DIR/avatar.jpg" "$image_url"; then
      avatar_path='"assets/avatar.jpg"'
    else
      echo "  ⚠ 头像下载失败，跳过"
    fi
  fi
fi

# ── 5. 生成原帖二维码 ────────────────────────────────────────────────────────
# 使用固定版本的 CLI，首次运行由 npx 下载并缓存；二维码始终指向 OG 原链接。
echo "→ 生成原帖二维码..."
npx --yes --package=qrcode@1.5.4 qrcode \
  --output="$WORK_DIR/assets/post-qr.png" \
  --width=240 --qzone=2 --error=H -- \
  "$og_url" >/dev/null

# 将 Unicode 𝕏 固定烧录在二维码几何中心，避免受 Typst 布局流影响。
x_font=$(fc-match -f '%{file}' ':charset=1d54f' | head -n 1)
if [ -z "$x_font" ]; then
  echo "error: 未找到支持 Unicode 𝕏 的字体" >&2
  exit 1
fi
# 先裁剪字形自身的边界再居中合成，避免字体字框/基线令 𝕏 视觉偏移。
magick -size 52x52 xc:none \
  -fill '#000000' -stroke '#ffffff' -strokewidth 2 \
  -draw 'roundrectangle 1,1 50,50 7,7' \
  \( -background none -fill '#ffffff' -font "$x_font" -pointsize 28 label:'𝕏' -trim +repage \) \
  -gravity center -compose over -composite "$WORK_DIR/assets/x-logo.png"
magick "$WORK_DIR/assets/post-qr.png" "$WORK_DIR/assets/x-logo.png" \
  -gravity center -compose over -composite "$WORK_DIR/assets/post-qr-logo.png"

# ── 6. 准备 Typst 模板 ───────────────────────────────────────────────────────
cp "$TEMPLATE_DIR/og-card.typ" "$WORK_DIR/"
 
# 如果头像下载成功，复制到 assets 目录
if [ "$avatar_path" != "null" ]; then
  cp "$WORK_DIR/avatar.jpg" "$WORK_DIR/assets/avatar.jpg"
fi
if [ "$post_image_path" != "null" ]; then
  cp "$WORK_DIR/post-image.jpg" "$WORK_DIR/assets/post-image.jpg"
fi
 
# ── 7. 构建 JSON 数据 ────────────────────────────────────────────────────────
DATA=$(jq -n \
  --arg title "$title" \
  --arg author "$author" \
  --arg handle "$handle" \
  --arg description "$desc" \
  --arg site_name "$site_name" \
  --arg url "$og_url" \
  --arg font_sans "$font_sans" \
  --arg font_cjk "$font_cjk" \
  --arg font_math "$font_math" \
  --arg font_emoji "$font_emoji" \
  --argjson avatar "$avatar_path" \
  --argjson post_image "$post_image_path" \
  '{
    title: $title,
    author: $author,
    handle: $handle,
    description: $description,
    site_name: $site_name,
    url: $url,
    font_sans: $font_sans,
    font_cjk: $font_cjk,
    font_math: $font_math,
    font_emoji: $font_emoji,
    avatar: $avatar,
    post_image: $post_image
  }'
)
 
echo "→ 编译 Typst 模板..."
(cd "$WORK_DIR" && typst compile \
  --input "data=$DATA" \
  --format png \
  og-card.typ \
  output.png)
 
# ── 8. 输出 ──────────────────────────────────────────────────────────────────
cp "$WORK_DIR/output.png" "$OUTPUT"
echo "✓ 已生成: $OUTPUT"
