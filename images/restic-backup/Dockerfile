# images/restic-backup/Dockerfile
# syntax=docker/dockerfile:1

ARG GO_IMAGE=docker.io/library/golang:1.23-alpine@sha256:383395b794dffa5b53012a212365d40c8e37109a626ca30d6151c8348d380b5f

FROM ${GO_IMAGE} AS builder
ARG resticVersion=v0.19.1
ARG opensshVersion=9.9p1

RUN apk add --no-cache \
    git \
    wget \
    build-base \
    autoconf \
    musl-dev \
    zlib-dev \
    zlib-static \
    openssl-dev \
    openssl-libs-static \
    ca-certificates

RUN mkdir -p /out

# restic — static Go binary, source-pinned (Renovate: resticVersion)
RUN CGO_ENABLED=0 go install github.com/restic/restic/cmd/restic@${resticVersion} \
    && cp "$(go env GOPATH)/bin/restic" /out/restic

# openssh client — built from source, statically linked (Renovate: opensshVersion).
# --with-privsep-path=/tmp: privsep only applies to sshd, not the ssh client,
# but configure requires a path that exists — /tmp is a harmless placeholder
# in the builder stage and is never carried into the final scratch image.
RUN wget -O /tmp/openssh.tar.gz \
      "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${opensshVersion}.tar.gz" \
    && tar -xzf /tmp/openssh.tar.gz -C /tmp \
    && cd /tmp/openssh-${opensshVersion} \
    && ./configure LDFLAGS=-static --with-privsep-path=/tmp \
    && make ssh \
    && cp ssh /out/ssh

COPY wrapper/ /src/wrapper/
RUN cd /src/wrapper \
    && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/wrapper . \
    && strip /out/restic /out/ssh \
    && printf 'root:x:0:0:root:/root:/bin/sh\n' > /out/passwd \
    && printf 'root:x:0:\n' > /out/group

FROM scratch
COPY --from=builder /out/restic /usr/bin/restic
COPY --from=builder /out/ssh /usr/bin/ssh
COPY --from=builder /out/wrapper /usr/local/bin/wrapper
COPY --from=builder /out/passwd /etc/passwd
COPY --from=builder /out/group /etc/group
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
ENTRYPOINT ["/usr/local/bin/wrapper"]
