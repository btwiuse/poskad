#!/usr/bin/env bash
set -euo pipefail
 
# ── 配置 ──────────────────────────────────────────────────────────────────────
TEMPLATE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
 
# ── 依赖检查 ──────────────────────────────────────────────────────────────────
for cmd in ogpk typst jq curl node npx magick fc-match fc-list; do
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
  local headers="$WORK_DIR/assets/${name}.headers"
  local output="$WORK_DIR/assets/${name}.png"
  local content_type extension

  echo "→ 下载${label}: $url"
  if curl -sfL --max-time "$timeout" -D "$headers" -o "$download" "$url"; then
    # ImageMagick 在某些平台无法仅凭内容识别 ICO。按照最终响应的 MIME 类型
    # 补上后缀，也让没有文件扩展名的 SVG/WebP favicon 可以正确解码。
    content_type=$(awk -F ': *' 'tolower($1) == "content-type" { value=tolower($2) } END { sub(/;.*/, "", value); gsub(/\r/, "", value); print value }' "$headers")
    extension=""
    case "$content_type" in
      image/x-icon|image/vnd.microsoft.icon) extension=".ico" ;;
      image/svg+xml) extension=".svg" ;;
      image/webp) extension=".webp" ;;
      image/avif) extension=".avif" ;;
      image/png) extension=".png" ;;
      image/jpeg) extension=".jpg" ;;
      image/gif) extension=".gif" ;;
    esac
    if [ -n "$extension" ]; then
      mv "$download" "${download}${extension}"
      download="${download}${extension}"
    fi
  fi
  if [ -f "$download" ]; then
    # ImageMagick 的 SVG 代理在部分 macOS 环境无法为 <text> 找到字体。
    # librsvg 会进行字体回退，优先用它转换 SVG；不可用时再保留 ImageMagick
    # 的 best-effort 路径，避免把 rsvg-convert 变成所有格式的硬依赖。
    if [[ "$extension" == ".svg" ]] && command -v rsvg-convert &>/dev/null; then
      if rsvg-convert --output "$output" "$download"; then
        return 0
      fi
    fi
    if magick "${download}[0]" -strip "$output"; then
      return 0
    fi
  fi
  echo "  ⚠ ${label}下载或转换失败，跳过"
  return 1
}

is_x_url=false
if [[ "$og_url" =~ ^https?://(www\.)?(x\.com|twitter\.com)(/|$) ]]; then
  is_x_url=true
fi

is_200_avatar=false
if [[ "$image_width" == "200" && "$image_height" == "200" ]] \
  || [[ "$image_url" == *_200x200.* ]]; then
  is_200_avatar=true
fi

avatar_path="null"
avatar_shape="round"
post_image_path="null"
if [ -n "$image_url" ] && [ "$image_url" != "null" ]; then
  if [[ "$is_x_url" == false && "$is_200_avatar" == false ]]; then
    avatar_shape="square"
  fi
  if [[ "$is_x_url" == true && -n "$handle" && ( "$image_width" != "400" || "$image_height" != "400" ) && "$is_200_avatar" == false ]]; then
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
      # 站外的普通 OG 图不是头像。以正方形容器展示，并取图片正中最大的方形，
      # 避免横图或竖图被压缩变形。
      if [[ "$is_x_url" == false && "$is_200_avatar" == false ]]; then
        magick "$WORK_DIR/assets/avatar.png" \
          -gravity center -crop '%[fx:min(w,h)]x%[fx:min(w,h)]+0+0' +repage \
          "$WORK_DIR/assets/avatar-square.png"
        mv "$WORK_DIR/assets/avatar-square.png" "$WORK_DIR/assets/avatar.png"
      fi
    fi
  fi
fi

# ── 5. 获取链接对应的 favicon，并生成原帖二维码 ──────────────────────────────
# favicon 没有统一路径或格式。优先使用页面声明的 icon（相对地址也会展开），
# 再尝试浏览器惯例的几个路径。所有候选都下载并交给 ImageMagick 解码，因此
# ICO、PNG、WebP、SVG 等常见格式都可用；全部失败时不放中心图标。
favicon_candidates() {
  local page_url="$1"
  local page_file="$WORK_DIR/favicon-page.html"
  local origin

  origin=$(node -e '
    try { console.log(new URL(process.argv[1]).origin) } catch { process.exit(1) }
  ' "$page_url") || return 0

  if curl -fsSL --max-time 12 \
    -A 'Mozilla/5.0 (compatible; Poskad/1.0; +https://github.com/gear/omfg)' \
    -H 'Accept: text/html,application/xhtml+xml' \
    -o "$page_file" "$page_url"; then
    node - "$page_url" "$page_file" <<'NODE'
const fs = require("fs");
const [pageUrl, pageFile] = process.argv.slice(2);
const html = fs.readFileSync(pageFile, "utf8");
const candidates = [];
const seen = new Set();
const add = (href) => {
  try {
    const url = new URL(href, pageUrl).href;
    if (/^https?:$/i.test(new URL(url).protocol) && !seen.has(url)) {
      seen.add(url);
      candidates.push(url);
    }
  } catch {}
};
const attr = (tag, name) => {
  const match = tag.match(new RegExp(`\\b${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))`, "i"));
  return match && (match[1] ?? match[2] ?? match[3]);
};
const links = html.match(/<link\b[^>]*>/gi) || [];
for (const kind of ["icon", "apple-touch-icon", "mask-icon"]) {
  for (const link of links) {
    const rel = (attr(link, "rel") || "").toLowerCase().split(/\s+/);
    if (rel.some(value => value === kind || value.startsWith(`${kind}-`))) add(attr(link, "href"));
  }
}
process.stdout.write(candidates.join("\n"));
NODE
  fi

  printf '\n%s/favicon.ico\n%s/favicon.png\n%s/apple-touch-icon.png\n' \
    "$origin" "$origin" "$origin"
}

favicon_path=""
while IFS= read -r favicon_url; do
  [ -n "$favicon_url" ] || continue
  if download_as_png "二维码图标" "$favicon_url" "favicon" 10; then
    favicon_path="$WORK_DIR/assets/favicon.png"
    break
  fi
done < <(favicon_candidates "$og_url")

# 使用固定版本的 CLI，首次运行由 npx 下载并缓存；二维码始终指向 OG 原链接。
echo "→ 生成原帖二维码..."
npx --yes --package=qrcode@1.5.4 qrcode \
  --output="$WORK_DIR/assets/post-qr.png" \
  --width=240 --qzone=2 --error=M -- \
  "$og_url" >/dev/null

if [ -n "$favicon_path" ]; then
  # 紧贴 favicon 的圆角白底保护 QR 纠错区；图标自身保持纵横比，避免拉伸。
  magick -size 42x42 xc:white \
    -fill '#ffffff' -stroke '#d0d7de' -strokewidth 1 \
    -draw 'roundrectangle 1,1 40,40 6,6' \
    \( "$favicon_path" -resize '34x34>' -background none -gravity center -extent 34x34 \
      \( -size 34x34 xc:none -fill white -draw 'roundrectangle 0,0 33,33 5,5' \) \
      -compose DstIn -composite \) \
    -gravity center -compose over -composite "$WORK_DIR/assets/qr-favicon.png"
  magick "$WORK_DIR/assets/post-qr.png" "$WORK_DIR/assets/qr-favicon.png" \
    -gravity center -compose over -composite "$WORK_DIR/assets/post-qr-logo.png"
else
  echo "  ⚠ 未找到可用 favicon，二维码不添加中心图标"
  cp "$WORK_DIR/assets/post-qr.png" "$WORK_DIR/assets/post-qr-logo.png"
fi

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
  --arg avatar_shape "$avatar_shape" \
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
    avatar_shape: $avatar_shape,
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
