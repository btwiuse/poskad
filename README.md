# Poskad

一个免登录的 Go + HTMX 前端，用于调用 `poskad.sh`。提交 URL 后，服务会显示实时日志并将成功结果保存为：

```text
output/<uuid-v7>/
├── image.webp
├── image.light.webp
├── image.dark.webp
└── src.url
```

首页只加载最新 12 张图片；滚动到末尾时由 HTMX 继续加载更早的记录。每个 URL 在生成期间按 SHA-256 键加锁，避免同一原文并发运行生成器。

## 本地运行

```bash
go run ./cmd/poskad
```

打开 `http://localhost:8080`。服务依赖现有脚本需要的命令：`ogpk`、`typst`、`jq`、`curl`、`npx`、`magick` 与 Fontconfig。

## 卡片主题

`poskad.sh` 使用单一模板，并可通过 `--theme` 选择一个或多个调色板，以及通过
`--format` 选择输出格式；默认同时生成 `light,dark` 主题的 WebP：

```bash
./poskad.sh --theme=light,dark --format=webp https://x.com/example/status/123 output/card.webp
```

上述命令会生成无损的 `output/card.light.webp`、`output/card.dark.webp`，并让
`output/card.webp` 指向浅色主题。若同时需要 PNG，可使用 `--format=png,webp`
并将输出文件名设为对应格式。网页、下载和系统分享均使用 WebP。

可选环境变量（也都可由同名语义的命令行参数覆盖）：

- `PORT`：监听端口，默认 `8080`
- `OUTPUT_DIR`：历史图片目录，默认 `output`
- `POSKAD_SCRIPT`：生成脚本路径，默认 `./poskad.sh`
- `WORK_DIR`：脚本工作目录，默认当前目录

例如：

```bash
go run ./cmd/poskad --port 3000 --output-dir ./output --poskad-script ./poskad.sh --work-dir .
```

运行 `go run ./cmd/poskad --help` 可查看全部参数。命令行参数优先于环境变量，例如 `PORT=8080 go run ./cmd/poskad --port 3000` 会监听 `3000`。

## Railway

仓库内的 `Dockerfile` 会构建嵌入 HTMX 静态资源的 Go 二进制，并在运行镜像中安装 Typst、ogpk、Node、ImageMagick 和所需字体。

在 Railway 创建 Dockerfile 服务即可。若需要保留生成历史，请挂载持久化 Volume 到 `/app/output`；未挂载 Volume 时，重新部署会丢失历史图片。
