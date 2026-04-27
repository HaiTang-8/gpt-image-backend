# syntax=docker/dockerfile:1

FROM --platform=$BUILDPLATFORM golang:1.22-bookworm AS build

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .

ARG TARGETOS=linux
ARG TARGETARCH=amd64

RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/gpt-image-backend ./cmd/gpt-image-backend && \
    mkdir -p /out/data

FROM gcr.io/distroless/base-debian12:nonroot

WORKDIR /app

COPY --from=build --chown=nonroot:nonroot /out/gpt-image-backend /app/gpt-image-backend
COPY --from=build --chown=nonroot:nonroot /out/data /app/data
COPY --chown=nonroot:nonroot config.example.yaml /app/config.example.yaml

USER nonroot:nonroot

EXPOSE 8080
VOLUME ["/app/data"]

ENTRYPOINT ["/app/gpt-image-backend"]
CMD ["-config", "/app/config.yaml"]
