# syntax=docker/dockerfile:1.7
FROM golang:1.27.1-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/relaydesk ./cmd/server

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /out/relaydesk /relaydesk
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/relaydesk"]
