# The build does not pin a `# syntax=` frontend: resolving it needs a registry
# round trip, while the builder shipped with a current Docker Engine already
# understands cache mounts.
# Simplified Dockerfile - uses pre-built widget.js and Flutter web assets
FROM golang:1.27.1-alpine AS build
WORKDIR /src
RUN apk add --no-cache git
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/tongyu ./cmd/server && \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/entrypoint ./cmd/entrypoint && \
    mkdir -p /out/uploads

FROM gcr.io/distroless/static-debian13:nonroot

# Use pre-built static files instead of building in container
COPY --from=build /out/tongyu /tongyu
COPY --from=build /out/entrypoint /entrypoint
COPY --chown=65532:65532 --from=build /out/uploads /data/uploads

# Copy pre-built widget.js
COPY packages/widget/dist/widget.js /static/widget.js

# 整包拷贝 Flutter Web：除 html 外还要有 main.dart.js / flutter.js 等，缺一不可
COPY apps/agent_console/build/web/ /static/console/
# 群邀请和消息列表使用根路径资源，发布时必须同步携带，避免独立群页404。
COPY apps/agent_console/build/web/groups.html apps/agent_console/build/web/group-interactions.js apps/agent_console/build/web/group-conference.js /static/
COPY apps/website/ /static/website/

ENV STATIC_DIR=/static
WORKDIR /data

EXPOSE 8080
USER root
ENTRYPOINT ["/entrypoint", "/tongyu"]

