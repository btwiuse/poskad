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
usage() {
  cat <<EOF
用法: $0 [--theme light,dark] <url> [output.png]

选项:
  --theme THEMES  逗号分隔的主题列表，默认 light,dark
EOF
}

THEME_LIST="light,dark"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --theme)
      if [[ $# -lt 2 ]]; then
        echo "error: --theme requires at least one theme" >&2
        exit 1
      fi
      THEME_LIST="${2:-}"
      shift 2
      ;;
    --theme=*)
      THEME_LIST="${1#*=}"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *) break ;;
  esac
done

IFS=',' read -r -a requested_themes <<< "$THEME_LIST"
THEMES=()
for theme in "${requested_themes[@]}"; do
  if [[ "$theme" != "dark" && "$theme" != "light" ]]; then
    echo "error: --theme only accepts light and dark" >&2
    exit 1
  fi
  if [[ " ${THEMES[*]} " != *" $theme "* ]]; then
    THEMES+=("$theme")
  fi
done
if [[ ${#THEMES[@]} -eq 0 ]]; then
  echo "error: --theme requires at least one theme" >&2
  exit 1
fi
URL="${1:?用法: $0 [--theme light,dark] <url> [output.png]}"
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

# 原链接仍用于二维码和分享；仅将卡片上的可见文本进行百分号解码，提升非 ASCII
# 路径的可读性，例如 /wiki/%E6%89%BF%E6%93%94%E7%89%B9%E8%B3%AA。
url_decode_for_display() {
  local remaining="$1"
  local decoded=""
  local hex character

  while [[ -n "$remaining" ]]; do
    if [[ "$remaining" =~ ^%([[:xdigit:]]{2}) ]]; then
      hex="${BASH_REMATCH[1]}"
      printf -v character '%b' "\\x$hex"
      decoded+="$character"
      remaining="${remaining:3}"
    else
      decoded+="${remaining:0:1}"
      remaining="${remaining:1}"
    fi
  done
  printf '%s' "$decoded"
}
display_url=$(url_decode_for_display "$og_url")

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

# OG metadata 不包含蓝标。对 X 帖子尽力查询公开 syndication 数据；查询失败
# 只是不显示认证标记，绝不阻塞图片生成。
verified=false
if [[ "$og_url" =~ ^https?://(www\.)?(x\.com|twitter\.com)/[^/]+/status/([0-9]+) ]]; then
  status_id="${BASH_REMATCH[3]}"
  echo "→ 查询 X 认证状态..."
  verification=$(curl -fsSL --max-time 8 "https://api.fxtwitter.com/status/${status_id}" \
    | jq -r '.tweet.author.verification.verified // false' 2>/dev/null || true)
  if [[ "$verification" == "true" ]]; then
    verified=true
  fi
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
if has_font "STIX Two Math"; then
  font_math="STIX Two Math"
elif has_font "STIX Math"; then
  font_math="STIX Math"
elif has_font "STIXGeneral"; then
  font_math="STIXGeneral"
else
  # 没有单独数学字体时，回退到已验证存在的正文字体，避免 Typst 警告。
  font_math="$font_sans"
fi

# ── 3. 准备模板资源 ──────────────────────────────────────────────────────────
mkdir -p "$WORK_DIR/assets"

# ── 4. 下载头像与帖子配图 ────────────────────────────────────────────────────
# X 对无图帖子通常把 400×400 的 profile image 放在 og:image。若尺寸并非
# 400×400 且 URL 也不是常见的 200x200 头像，则把它视为帖子配图，头像改由
# unavatar 根据从 og:title 拆出的 @用户名获取。
download_as_png() {
  local label="$1"
  local url="$2"
  local name="$3"
  local timeout="$4"
  local download="$WORK_DIR/assets/${name}.download"
  local output="$WORK_DIR/assets/${name}.png"

  echo "→ 下载${label}: $url"
  if curl -sfL --max-time "$timeout" -o "$download" "$url" \
    && magick "${download}[0]" -strip "$output"; then
    return 0
  fi
  echo "  ⚠ ${label}下载或转换失败，跳过"
  return 1
}

avatar_path="null"
post_image_path="null"
if [ -n "$image_url" ] && [ "$image_url" != "null" ]; then
  if [[ -n "$handle" && ( "$image_width" != "400" || "$image_height" != "400" ) && "$image_url" != *_200x200.jpg ]]; then
    avatar_url="https://unavatar.io/x/${handle#@}"
    if download_as_png "头像" "$avatar_url" "avatar" 15; then
      avatar_path='"assets/avatar.png"'
    fi

    if download_as_png "帖子配图" "$image_url" "post-image" 20; then
      post_image_path='"assets/post-image.png"'
    fi
  else
    if download_as_png "头像" "$image_url" "avatar" 10; then
      avatar_path='"assets/avatar.png"'
    fi
  fi
fi

# ── 5. 生成原帖二维码 ────────────────────────────────────────────────────────
# 使用固定版本的 CLI，首次运行由 npx 下载并缓存；二维码始终指向 OG 原链接。
echo "→ 生成原帖二维码..."
npx --yes --package=qrcode@1.5.4 qrcode \
  --output="$WORK_DIR/assets/post-qr.png" \
  --width=240 --qzone=2 --error=M -- \
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
cp "$TEMPLATE_DIR/verified.svg" "$WORK_DIR/assets/verified.svg"
 
# ── 7. 构建 JSON 数据 ────────────────────────────────────────────────────────
BASE_DATA=$(jq -n \
  --arg title "$title" \
  --arg author "$author" \
  --arg handle "$handle" \
  --arg description "$desc" \
  --arg site_name "$site_name" \
  --arg url "$display_url" \
  --arg font_sans "$font_sans" \
  --arg font_cjk "$font_cjk" \
  --arg font_math "$font_math" \
  --arg font_emoji "$font_emoji" \
  --argjson verified "$verified" \
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
    verified: $verified,
    avatar: $avatar,
    post_image: $post_image
  }'
)
 
output_base="${OUTPUT%.png}"
if [[ "$output_base" == "$OUTPUT" ]]; then
  echo "error: output filename must end in .png" >&2
  exit 1
fi

echo "→ 编译 Typst 模板..."
for theme in "${THEMES[@]}"; do
  data=$(jq --arg theme "$theme" '. + {theme: $theme}' <<< "$BASE_DATA")
  theme_output="${output_base}.${theme}.png"
  (cd "$WORK_DIR" && typst compile \
    --input "data=$data" \
    --format png \
    og-card.typ \
    "output-${theme}.png")
  # Typst 会保留 Alpha 通道；导出的分享图使用不透明 RGB PNG，避免透明边缘。
  magick "$WORK_DIR/output-${theme}.png" -alpha off "$theme_output"
  echo "✓ 已生成: $theme_output"
done

# Legacy consumers still request image.png. Prefer the light result, which is
# the default web theme; for a single-theme invocation, link to that result.
legacy_theme="light"
if [[ " ${THEMES[*]} " != *" light "* ]]; then
  legacy_theme="${THEMES[0]}"
fi
ln -sfn "$(basename "${output_base}.${legacy_theme}.png")" "$OUTPUT"
echo "✓ 已生成: $OUTPUT -> $(basename "${output_base}.${legacy_theme}.png")"
