// =============================================================================
// X POST LINK CARD TEMPLATE
// =============================================================================
// 用法: typst compile --input data='<json>' og-card.typ output.png
 
// ── 配色 ──────────────────────────────────────────────────────────────────────
 
#let colors = (
  bg: rgb("#000000"),
  card: rgb("#000000"),
  text: rgb("#f7f9f9"),
  text-dim: rgb("#8b98a5"),
  border: rgb("#2f3336"),
  blue: rgb("#1d9bf0"),
  qr-bg: rgb("#ffffff"),
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
    clip: true, fill: colors.border,
    stroke: 0.75pt + colors.border, radius: 50%, inset: 1pt,
    box(clip: true, radius: 50%, image(path, width: size))
  )
}

#let verified-badge() = {
  box(width: 15pt, height: 15pt, inset: 0pt)[
    #image("assets/verified.svg", width: 100%)
  ]
}
 
// ── 数据加载 ─────────────────────────────────────────────────────────────────
 
#let data = json(bytes(sys.inputs.data))
 
// ── 页面设置 ─────────────────────────────────────────────────────────────────
 
// 导出的 PNG 没有透明留白，且外框为直角；网页端可按自身视觉添加圆角。
#set page(width: 600pt, height: auto, margin: 0pt, fill: colors.card)
// 字体由脚本根据当前运行环境选择，避免 macOS 与 Linux 容器的缺字警告。
#set text(font: (data.font_sans, data.font_cjk, data.font_math, data.font_emoji), fill: colors.text)
 
// ── 主内容 ───────────────────────────────────────────────────────────────────
 
#block(width: 100%, inset: 18pt)[
      // 𝕏 独立置于帖首；二维码则与原链接一起置于正文分隔线下方。
      #place(top + right)[
        #text(size: 24pt, weight: "bold", fill: colors.text, "𝕏")
      ]
      #table(
        columns: (auto, 1fr),
        column-gutter: 10pt,
        inset: 0pt,
        align: (left, horizon),
        if data.at("avatar", default: none) != none {
          render-avatar(data.avatar, size: 40pt)
        } else {
          circle(radius: 20pt, fill: colors.border)
        },
        [
          // X 使用 40px 头像、15px 名称/handle；在 2× PNG 中保持相同视觉比例。
          #stack(dir: ttb, spacing: 0pt,
            [
              #text(size: 15pt, weight: "bold", data.author)
              #if data.at("verified", default: false) { h(2pt); verified-badge() }
            ],
            [#if data.handle != "" { text(size: 15pt, fill: colors.text-dim, data.handle) }],
          )
        ],
      )
      #v(8pt)
      #block(width: 100%)[
        #text(size: 20pt, weight: "regular",
          data.description
        )
      ]
      #if data.at("post_image", default: none) != none {
        v(14pt)
        box(width: 100%, clip: true, radius: 10pt)[
          #image(data.post_image, width: 100%)
        ]
      }
      #v(12pt)
      #line(length: 100%, stroke: 0.5pt + colors.border)
      #v(10pt)
      // 页脚在 HR 下方正常流式排版：正文再长也不会与二维码重叠。
      #table(
        columns: (1fr, auto),
        column-gutter: 16pt,
        inset: 0pt,
        align: (left, bottom),
        table.cell(align: left + bottom)[
          #text(size: 9pt, fill: colors.text-dim, data.url)
        ],
        [
          #align(right)[
            #box(fill: colors.qr-bg, radius: 7pt, inset: 6pt)[
              #image("assets/post-qr-logo.png", width: 78pt)
            ]
          ]
        ],
      )
]
