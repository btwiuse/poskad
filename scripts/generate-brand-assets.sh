#!/usr/bin/env bash
set -euo pipefail

# favicon.svg is the source of truth. Regenerate every raster brand asset with:
#   ./scripts/generate-brand-assets.sh
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_svg="$root/web/static/favicon.svg"
static_dir="$root/web/static"

command -v rsvg-convert >/dev/null || {
  echo "error: librsvg (rsvg-convert) is required" >&2
  exit 1
}
command -v magick >/dev/null || {
  echo "error: ImageMagick 7 (magick) is required" >&2
  exit 1
}

render_icon() {
  local size=$1
  local destination=$2
  rsvg-convert --width "$size" --height "$size" "$source_svg" \
    | magick png:- -strip "$destination"
}

render_icon 180 "$static_dir/apple-touch-icon.png"
render_icon 32 "$static_dir/favicon-32.png"
render_icon 192 "$static_dir/favicon-192.png"
render_icon 512 "$static_dir/favicon-512.png"

og_logo=$(mktemp)
trap 'rm -f "$og_logo"' EXIT
rsvg-convert --width 512 --height 512 "$source_svg" -o "$og_logo"
magick -size 1200x630 'xc:#000000' \
  "$og_logo" \
  -gravity center -compose over -composite \
  -strip \
  "$static_dir/og-image.png"
