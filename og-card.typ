// =============================================================================
// OG LINK CARD TEMPLATE
// =============================================================================
// 用法: typst compile --input data='<json>' og-card.typ output.png
 
// ── 配色 ──────────────────────────────────────────────────────────────────────
 
#let colors = (
  bg: oklch(15%, 0.02, 260deg),
  card-bg: oklch(22%, 0.02, 260deg),
  accent: oklch(65%, 0.15, 260deg),
  text: oklch(92%, 0.01, 260deg),
  text-dim: oklch(65%, 0.02, 260deg),
  avatar-border: oklch(40%, 0.05, 260deg),
  border: oklch(35%, 0.03, 260deg),
  site-badge-bg: oklch(30%, 0.04, 260deg),
  site-badge-text: oklch(78%, 0.04, 260deg),
)
 
// ── 文本截断 ──────────────────────────────────────────────────────────────────
 
#let truncate(text, max-lines: 2) = {
  layout(size => {
    let t = text
    let max-h = measure(linebreak()).height * max-lines
    if measure(width: size.width, t).height <= max-h {
      return t
    }
    while measure(width: size.width, t + "…").height > max-h {
      let chars = t.clusters()
      if chars.len() == 0 { break }
      t = chars.slice(0, chars.len() - 1).join().trim()
    }
    t + "…"
  })
}
 
// ── 圆形头像 ─────────────────────────────────────────────────────────────────
 
#let render-avatar(path, size: 48pt) = {
  box(
    clip: true, fill: colors.avatar-border,
    stroke: 1.5pt + colors.accent, radius: 50%, inset: 2pt,
    box(clip: true, radius: 50%, image(path, width: size))
  )
}
 
// ── 数据加载 ─────────────────────────────────────────────────────────────────
 
#let data = json(bytes(sys.inputs.data))
 
// ── 页面设置 ─────────────────────────────────────────────────────────────────
 
#set page(width: 600pt, height: 315pt, margin: 0pt, fill: colors.bg)
#set text(font: ("Fira Sans", "Noto Color Emoji", "Noto Sans CJK SC"), fill: colors.text)
 
// 底部渐变装饰线
#place(bottom,
  rect(width: 100%, height: 3pt, fill: colors.accent)
)
 
// ── 主内容 ───────────────────────────────────────────────────────────────────
 
#block(
  width: 100%, height: 100%,
  inset: 30pt,
  clip: true,
 
  // ── 上半部分：头像 + 标题 ──
  {
    // 头像 + 标题并排
    if data.at("avatar", default: none) != none {
      table(
        columns: (auto, 1fr),
        column-gutter: 12pt,
        align: (left, left),
        render-avatar(data.avatar, size: 52pt),
        [
          #block(
            text(size: 22pt, weight: "bold", fill: colors.text,
              truncate(data.title, max-lines: 1)
            )
          )
          #if data.at("site_name", default: none) != none {
            v(4pt)
            box(
              fill: colors.site-badge-bg, radius: 0.2em,
              inset: (x: 0.6em, y: 0.2em),
              text(size: 9pt, weight: "medium", fill: colors.site-badge-text,
                upper(data.site_name)
              )
            )
          }
        ]
      )
    } else {
      // 无头像时仅显示标题
      block(
        text(size: 22pt, weight: "bold", fill: colors.text,
          truncate(data.title, max-lines: 1)
        )
      )
      // site badge
      if data.at("site_name", default: none) != none {
        v(4pt)
        box(
          fill: colors.site-badge-bg, radius: 0.2em,
          inset: (x: 0.6em, y: 0.2em),
          text(size: 9pt, weight: "medium", fill: colors.site-badge-text,
            upper(data.site_name)
          )
        )
      }
    }
 
    // ── 分隔线 ──
    v(12pt)
    line(length: 100%, stroke: 0.5pt + colors.border)
    v(12pt)
 
    // ── 描述 ──
    if data.at("description", default: none) != none {
      block(
        text(size: 14pt, fill: colors.text-dim,
          truncate(data.description, max-lines: 4)
        )
      )
    }
 
    // ── 底部 URL ──
    place(bottom + left,
      text(size: 10pt, fill: colors.text-dim, style: "italic",
        truncate(data.url, max-lines: 1)
      )
    )
  }
)
