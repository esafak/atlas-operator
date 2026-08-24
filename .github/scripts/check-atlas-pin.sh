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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import re
import os
from pathlib import Path

root = Path(os.environ["REPO_ROOT"])
makefile = (root / "Makefile").read_text()
dockerfile = (root / "Dockerfile").read_text()
integration = (root / ".github/workflows/integration.yaml").read_text()
release_files = [
    (root / ".github/workflows/cd-image-canary-release.yaml").read_text(),
    (root / ".github/workflows/cd-operator-release.yaml").read_text(),
]

keys = {
    "repository": "ATLAS_REPOSITORY",
    "release": "ATLAS_RELEASE",
    "commit": "ATLAS_COMMIT",
    "asset-base": "ATLAS_ASSET_BASE",
    "amd64-sha256": "ATLAS_AMD64_SHA256",
    "arm64-sha256": "ATLAS_ARM64_SHA256",
}

def one(pattern, text, name):
    matches = re.findall(pattern, text, re.MULTILINE)
    if len(matches) != 1:
        raise SystemExit(f"expected one {name}, found {len(matches)}")
    return matches[0].strip()

values = {
    key: one(rf"^{re.escape(var)}\s*\?=\s*(\S+)$", makefile, f"Makefile {var}")
    for key, var in keys.items()
}
values["asset-base"] = f"https://github.com/{values['repository']}/releases/download/{values['release']}"
if "ATLAS_ASSET_BASE ?= https://github.com/$(ATLAS_REPOSITORY)/releases/download/$(ATLAS_RELEASE)" not in makefile:
    raise SystemExit("Makefile Atlas asset base is not derived from the repository and release")

for key, var in keys.items():
    docker_value = one(rf"^ARG\s+{re.escape(var)}=(\S+)$", dockerfile, f"Dockerfile {var}")
    if docker_value != values[key]:
        raise SystemExit(f"{var} differs between Makefile and Dockerfile")
    for workflow in release_files:
        if not re.search(rf"^\s+{re.escape(var)}={re.escape(values[key])}$", workflow, re.MULTILINE):
            raise SystemExit(f"{var} is missing or differs in a release workflow")
    action_value = one(rf"^\s+{re.escape(key)}:\s*(\S+)$", integration, f"integration {key}")
    if action_value != values[key]:
        raise SystemExit(f"{var} differs between Makefile and integration action inputs")

identity = r"^https://github\.com/esafak/atlas/\.github/workflows/cli-prerelease_oss\.yaml@refs/heads/dev$"
issuer = "https://token.actions.githubusercontent.com"
docker_identity = r"^https://github\.com/${ATLAS_REPOSITORY}/\.github/workflows/cli-prerelease_oss\.yaml@refs/heads/${ATLAS_RELEASE}$"
if docker_identity not in dockerfile:
    raise SystemExit("Dockerfile Cosign identity does not authorize the fork dev workflow")
if f'--certificate-oidc-issuer {issuer}' not in dockerfile:
    raise SystemExit("Dockerfile Cosign issuer differs from the pinned issuer")
if f"cosign-identity: '{identity}'" not in integration:
    raise SystemExit("integration Cosign identity is not pinned to the fork dev workflow")
if f"cosign-oidc-issuer: {issuer}" not in integration:
    raise SystemExit("integration Cosign issuer is not pinned")

for workflow in release_files:
    label = one(r"io\.ariga\.atlas\.version=([^\n]+)", workflow, "Atlas OCI label")
    if label != f"{values['release']}-{values['commit']}":
        raise SystemExit("OCI Atlas version label differs from the pinned commit")
print(f"Atlas pin is consistent: {values['repository']} {values['release']}-{values['commit']}")
PY
