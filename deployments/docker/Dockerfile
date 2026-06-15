FROM golang:1.25-alpine AS builder

ENV GOPROXY=https://goproxy.cn,https://proxy.golang.org,direct

WORKDIR /src

# Cache dependencies
COPY go.mod go.sum ./
RUN go mod download

# Build
COPY . .
ARG VERSION=dev
ARG GIT_COMMIT=unknown
ARG BUILD_DATE=unknown

RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w \
      -X github.com/grandinfo/gi-conMon/internal/version.Version=${VERSION} \
      -X github.com/grandinfo/gi-conMon/internal/version.GitCommit=${GIT_COMMIT} \
      -X github.com/grandinfo/gi-conMon/internal/version.BuildDate=${BUILD_DATE} \
      -X github.com/grandinfo/gi-conMon/internal/version.GoVersion=$(go version | cut -d' ' -f3)" \
    -o /out/conmon \
    ./cmd/conmon

# ---- Final image ----
FROM alpine:3.20

# Install runtime deps (ca-certs for HTTPS probes, tzdata for timezones)
RUN apk --no-cache add ca-certificates tzdata && \
    adduser -D -u 1000 -s /sbin/nologin conmon

COPY --from=builder /out/conmon /usr/local/bin/conmon

# Default config and data directories
RUN mkdir -p /etc/conmon /var/lib/conmon /var/log/conmon && \
    chown -R conmon:conmon /var/lib/conmon /var/log/conmon

COPY configs/conmon.yaml /etc/conmon/conmon.yaml

USER conmon

EXPOSE 11080 11090

HEALTHCHECK --interval=10s --timeout=5s --retries=3 \
    CMD wget -qO- http://localhost:11080/health || exit 1

ENTRYPOINT ["/usr/local/bin/conmon"]
CMD ["server", "-c", "/etc/conmon/conmon.yaml"]
