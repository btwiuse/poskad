FROM golang:1.26-bookworm AS build
WORKDIR /src
COPY go.mod go.sum app.go command.go ./
COPY web ./web
COPY cmd ./cmd
RUN mkdir -p /out \
    && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags='-s -w' -o /out/poskad ./cmd/poskad \
    && GOBIN=/out go install github.com/btwiuse/ogpk@latest

# ImageMagick 7; Bookworm variant keeps it compatible with the packages below.
FROM dpokidov/imagemagick:7.1.1-47-bookworm
ARG TYPST_VERSION=0.15.1
WORKDIR /app
RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl fontconfig fonts-noto-cjk fonts-noto-color-emoji fonts-stix jq nodejs npm xz-utils \
    && curl -fsSL "https://github.com/typst/typst/releases/download/v${TYPST_VERSION}/typst-x86_64-unknown-linux-musl.tar.xz" \
       | tar -xJ --strip-components=1 -C /usr/local/bin "typst-x86_64-unknown-linux-musl/typst" \
    && apt-get purge -y --auto-remove xz-utils \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/poskad /usr/local/bin/poskad
COPY --from=build /out/ogpk /usr/local/bin/ogpk
COPY og2png.sh og-card.typ verified.svg ./
RUN chmod +x ./og2png.sh \
    && mkdir -p /app/output \
    && fc-cache -f \
    && magick -version
ENV PORT=8080 OUTPUT_DIR=/app/output OG2PNG_SCRIPT=/app/og2png.sh WORK_DIR=/app
EXPOSE 8080
# The ImageMagick base image uses `convert` as its default entrypoint.
ENTRYPOINT []
CMD ["poskad"]
