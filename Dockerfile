# The build does not pin a `# syntax=` frontend: resolving it needs a registry
# round trip, while the builder shipped with a current Docker Engine already
# understands cache mounts.
FROM golang:1.27.1-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/relaydesk ./cmd/server && \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/entrypoint ./cmd/entrypoint && \
    mkdir -p /out/uploads

FROM public.ecr.aws/docker/library/node:24-alpine AS widget-build
WORKDIR /widget
COPY packages/widget/package.json packages/widget/package-lock.json ./
RUN npm ci
COPY packages/widget/tsconfig.json ./
COPY packages/widget/src ./src
RUN npm run build

FROM ghcr.io/cirruslabs/flutter:3.24.5 AS console-build
WORKDIR /console
COPY apps/agent_console/pubspec.yaml ./
RUN flutter pub get
COPY apps/agent_console/analysis_options.yaml ./
COPY apps/agent_console/lib ./lib
COPY apps/agent_console/web ./web
RUN flutter build web --release --base-href /console/ --no-web-resources-cdn --pwa-strategy=none

FROM gcr.io/distroless/static-debian13:nonroot

# /data/uploads is created here and owned by the nonroot user, so a fresh named
# volume is seeded with the right ownership. A volume that already exists with a
# different owner is repaired by the entrypoint, which starts as root and drops
# privileges before exec'ing the server.
COPY --from=build /out/relaydesk /relaydesk
COPY --from=build /out/entrypoint /entrypoint
COPY --chown=65532:65532 --from=build /out/uploads /data/uploads
COPY --from=widget-build /widget/dist/widget.js /static/widget.js
COPY --from=console-build /console/build/web /static/console
ENV STATIC_DIR=/static
WORKDIR /data

EXPOSE 8080
# Root only for the ownership fix; the server itself never runs as root.
USER root
ENTRYPOINT ["/entrypoint", "/relaydesk"]
