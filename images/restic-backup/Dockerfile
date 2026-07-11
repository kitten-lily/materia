# images/restic-backup/Dockerfile
# syntax=docker/dockerfile:1

ARG GO_IMAGE=docker.io/library/golang:1.23-alpine@sha256:383395b794dffa5b53012a212365d40c8e37109a626ca30d6151c8348d380b5f

FROM ${GO_IMAGE} AS builder
ARG resticVersion=v0.18.0
ARG opensshVersion=9.9p1

RUN apk add --no-cache \
    git \
    build-base \
    autoconf \
    musl-dev \
    zlib-static \
    openssl-libs-static \
    ca-certificates

RUN mkdir -p /out

# restic — static Go binary, source-pinned (Renovate: resticVersion)
RUN CGO_ENABLED=0 go install github.com/restic/restic/cmd/restic@${resticVersion} \
    && cp "$(go env GOPATH)/bin/restic" /out/restic
