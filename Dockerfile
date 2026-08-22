# syntax = docker/dockerfile:1.4.1
# Copyright 2023 The Atlas Operator Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Build the manager binary
FROM golang:1.26.6-alpine3.24 AS builder
ARG TARGETOS
ARG TARGETARCH
ARG OPERATOR_VERSION

WORKDIR /workspace
# Copy the Go Modules manifests
COPY go.mod go.mod
COPY go.sum go.sum
# cache deps before building and copying source so that we don't need to re-download as much
# and so that source changes don't invalidate our downloaded layer
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go mod download

# Copy the go source
COPY cmd/main.go cmd/main.go
COPY api/ api/
COPY internal/ internal/

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} CGO_ENABLED=0 \
    go build -ldflags "-X 'main.version=${OPERATOR_VERSION}'" \
    -o manager -a cmd/main.go

FROM golang:1.26.6-bookworm AS atlas
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/* && \
    go install github.com/sigstore/cosign/v2/cmd/cosign@v2.6.3
ARG ATLAS_REPOSITORY=esafak/atlas
ARG ATLAS_RELEASE=dev
ARG ATLAS_COMMIT=01c1774a6484596092eed387d7cdda9355e5a896
ARG ATLAS_ASSET_BASE=https://github.com/esafak/atlas/releases/download/dev
ARG ATLAS_AMD64_SHA256=c586d2c3d2014020a83c820637e9f5e9855d69835564b454a33ca7f6577aaa5c
ARG ATLAS_ARM64_SHA256=b860900e2f9640e8305882d0b5e812af7430a91332f48ff70a054c3564f345ab
ARG TARGETARCH
RUN set -eux; \
    case "${TARGETARCH}" in amd64) sha="${ATLAS_AMD64_SHA256}";; arm64) sha="${ATLAS_ARM64_SHA256}";; *) echo "unsupported TARGETARCH=${TARGETARCH}; Atlas publishes only amd64 and arm64" >&2; exit 1;; esac; \
    asset="atlas-linux-${TARGETARCH}"; \
    for attempt in 1 2 3 4 5; do \
      curl -fsSL --retry 2 "${ATLAS_ASSET_BASE}/${asset}" -o "/tmp/${asset}" && \
      curl -fsSL --retry 2 "${ATLAS_ASSET_BASE}/${asset}.bundle" -o "/tmp/${asset}.bundle" && break; \
      sleep $((attempt * 2)); \
    done; \
    test -s "/tmp/${asset}" || { echo "Atlas download failed after retries" >&2; exit 1; }; \
    test -s "/tmp/${asset}.bundle" || { echo "Atlas bundle download failed after retries" >&2; exit 1; }; \
    echo "${sha}  /tmp/${asset}" | sha256sum -c -; \
    /go/bin/cosign verify-blob --bundle "/tmp/${asset}.bundle" \
      --certificate-identity-regexp "^https://github\.com/${ATLAS_REPOSITORY}/\.github/workflows/cli-prerelease_oss\.yaml@refs/heads/${ATLAS_RELEASE}$" \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com \
      "/tmp/${asset}"; \
    install -m 0755 "/tmp/${asset}" /usr/local/bin/atlas; \
    atlas version | grep -F "development"; \
    rm -f /tmp/${asset} "/tmp/${asset}.bundle"

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /
COPY --from=builder /workspace/manager .
COPY --from=atlas /usr/local/bin/atlas /usr/local/bin
RUN chmod +x /usr/local/bin/atlas
ENV ATLAS_KUBERNETES_OPERATOR=1
USER 65532:65532
ENTRYPOINT ["/manager"]
