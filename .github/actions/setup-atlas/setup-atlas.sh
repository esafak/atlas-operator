#!/usr/bin/env bash
# Copyright 2026 The Atlas Operator Authors.
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

set -euo pipefail

case "${RUNNER_ARCH:-}" in
  X64) atlas_arch=amd64; cosign_arch=amd64 ;;
  ARM64) atlas_arch=arm64; cosign_arch=arm64 ;;
  *) echo "unsupported GitHub runner architecture: ${RUNNER_ARCH:-<unset>}" >&2; exit 1 ;;
esac

case "$atlas_arch" in
  amd64) expected_sha="$ATLAS_AMD64_SHA256" ;;
  arm64) expected_sha="$ATLAS_ARM64_SHA256" ;;
esac
test -n "$expected_sha" || { echo "Atlas checksum is empty" >&2; exit 1; }

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
asset="atlas-linux-${atlas_arch}"
cosign_url="https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-${cosign_arch}"

curl --fail --silent --show-error --location --retry 3 "$cosign_url" -o "$workdir/cosign"
test -s "$workdir/cosign" || { echo "Cosign download was empty" >&2; exit 1; }
install -m 0755 "$workdir/cosign" "$workdir/cosign-bin"

curl --fail --silent --show-error --location --retry 3 \
  "$ATLAS_ASSET_BASE/$asset" -o "$workdir/$asset"
curl --fail --silent --show-error --location --retry 3 \
  "$ATLAS_ASSET_BASE/$asset.bundle" -o "$workdir/$asset.bundle"
test -s "$workdir/$asset" || { echo "Atlas download was empty" >&2; exit 1; }
test -s "$workdir/$asset.bundle" || { echo "Atlas bundle download was empty" >&2; exit 1; }

echo "$expected_sha  $workdir/$asset" | sha256sum --check --strict
"$workdir/cosign-bin" verify-blob --bundle "$workdir/$asset.bundle" \
  --certificate-identity-regexp "$COSIGN_IDENTITY" \
  --certificate-oidc-issuer "$COSIGN_OIDC_ISSUER" "$workdir/$asset"

mkdir -p "$HOME/.local/bin"
install -m 0755 "$workdir/$asset" "$HOME/.local/bin/atlas"
echo "$HOME/.local/bin" >> "$GITHUB_PATH"
"$HOME/.local/bin/atlas" version | grep -Fx "atlas version ${ATLAS_RELEASE}-${ATLAS_COMMIT}"
