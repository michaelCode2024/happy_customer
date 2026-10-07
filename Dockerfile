# The build does not pin a `# syntax=` frontend: resolving it needs a registry
# round trip, while the builder shipped with a current Docker Engine already
# understands cache mounts.
FROM golang:1.27.1-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/relaydesk ./cmd/server && \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/entrypoint ./cmd/entrypoint && \
    mkdir -p /out/uploads

FROM gcr.io/distroless/static-debian13:nonroot

# /data/uploads is created here and owned by the nonroot user, so a fresh named
# volume is seeded with the right ownership. A volume that already exists with a
# different owner is repaired by the entrypoint, which starts as root and drops
# privileges before exec'ing the server.
COPY --from=build /out/relaydesk /relaydesk
COPY --from=build /out/entrypoint /entrypoint
COPY --chown=65532:65532 --from=build /out/uploads /data/uploads
WORKDIR /data

EXPOSE 8080
# Root only for the ownership fix; the server itself never runs as root.
USER root
ENTRYPOINT ["/entrypoint", "/relaydesk"]
