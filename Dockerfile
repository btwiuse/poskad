FROM golang:1.26-bookworm AS build
WORKDIR /src
COPY go.mod main.go ./
COPY web ./web
RUN mkdir -p /out \
    && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags='-s -w' -o /out/og2png-web . \
    && GOBIN=/out go install github.com/btwiuse/ogpk@latest

FROM debian:bookworm-slim
ARG TYPST_VERSION=0.15.1
WORKDIR /app
RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl fontconfig fonts-noto-cjk fonts-noto-color-emoji fonts-stix imagemagick jq nodejs npm xz-utils \
    && curl -fsSL "https://github.com/typst/typst/releases/download/v${TYPST_VERSION}/typst-x86_64-unknown-linux-musl.tar.xz" \
       | tar -xJ --strip-components=1 -C /usr/local/bin "typst-x86_64-unknown-linux-musl/typst" \
    && apt-get purge -y --auto-remove xz-utils \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/og2png-web /usr/local/bin/og2png-web
COPY --from=build /out/ogpk /usr/local/bin/ogpk
COPY og2png.sh og-card.typ ./
RUN chmod +x ./og2png.sh \
    && mkdir -p /app/output \
    && fc-cache -f
ENV PORT=8080 OUTPUT_DIR=/app/output OG2PNG_SCRIPT=/app/og2png.sh WORK_DIR=/app
EXPOSE 8080
CMD ["og2png-web"]
