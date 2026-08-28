#!/usr/bin/env python3
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

"""Refresh the checked-in Atlas dev release pin.

The release API supplies the source commit and asset digests. The binaries are
downloaded and hashed independently before any repository files are changed.
"""

import argparse
import hashlib
import json
import re
import socket
import subprocess
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
socket.setdefaulttimeout(60)
FILES = [
    ROOT / "Makefile",
    ROOT / "Dockerfile",
    ROOT / ".github/workflows/integration.yaml",
    ROOT / ".github/workflows/cd-image-canary-release.yaml",
    ROOT / ".github/workflows/cd-operator-release.yaml",
]


def release_metadata(repository: str, release: str) -> dict:
    """Fetch and decode metadata for a GitHub release tag."""
    try:
        output = subprocess.check_output(
            ["gh", "api", f"repos/{repository}/releases/tags/{release}"],
            text=True,
            timeout=120,
        )
    except FileNotFoundError:
        raise SystemExit("gh is required; install GitHub CLI first")
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"could not read {repository}:{release} from GitHub ({error.returncode})")
    return json.loads(output)


def asset_digest(asset: dict, repository: str, release: str, destination: Path) -> str:
    """Download an asset and verify it against GitHub's published digest."""
    name = asset["name"]
    expected = asset.get("digest", "")
    if not expected.startswith("sha256:"):
        raise SystemExit(f"GitHub did not provide a SHA-256 digest for {name}")
    url = f"https://github.com/{repository}/releases/download/{release}/{name}"
    try:
        with urllib.request.urlopen(url, timeout=60) as response, destination.open("wb") as output:
            hasher = hashlib.sha256()
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
                hasher.update(chunk)
    except urllib.error.URLError as error:
        raise SystemExit(f"could not download {name}: {error}")
    digest = hasher.hexdigest()
    if digest != expected.removeprefix("sha256:"):
        raise SystemExit(f"downloaded {name} does not match GitHub's digest")
    return digest


def verify_signature(binary: Path, bundle: Path) -> None:
    """Verify a binary's keyless Cosign signature and workflow identity."""
    try:
        subprocess.run(
            [
                "cosign",
                "verify-blob",
                "--bundle",
                str(bundle),
                "--certificate-identity-regexp",
                r"^https://github\.com/esafak/atlas/\.github/workflows/cli-prerelease_oss\.yaml@refs/heads/dev$",
                "--certificate-oidc-issuer",
                "https://token.actions.githubusercontent.com",
                str(binary),
            ],
            check=True,
            timeout=120,
        )
    except FileNotFoundError:
        raise SystemExit("cosign is required; run `mise install` first")
    except subprocess.CalledProcessError:
        raise SystemExit(f"Cosign verification failed for {binary.name}")


def verify_binary_commit(binary: Path, commit: str) -> None:
    """Verify the binary embeds the source commit reported by the release."""
    expected = f"dev-{commit}".encode()
    versions = set(re.findall(rb"dev-[0-9a-f]{40}", binary.read_bytes()))
    if versions != {expected}:
        found = ", ".join(version.decode() for version in sorted(versions)) or "none"
        raise SystemExit(f"{binary.name} embeds {found}; expected dev-{commit}")


def main() -> None:
    """Verify the latest Atlas dev assets and update all checked-in consumers."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default="esafak/atlas")
    parser.add_argument("--release", default="dev")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.repository != "esafak/atlas":
        raise SystemExit("--repository must be esafak/atlas because the Cosign policy is repository-specific")
    if args.release != "dev":
        raise SystemExit("this updater currently supports only the mutable dev release")

    metadata = release_metadata(args.repository, args.release)
    commit = metadata.get("target_commitish", "")
    if len(commit) != 40 or any(character not in "0123456789abcdef" for character in commit):
        raise SystemExit(f"release target_commitish is not a full commit SHA: {commit!r}")
    assets = {asset["name"]: asset for asset in metadata["assets"]}
    hashes = {}
    with tempfile.TemporaryDirectory() as temporary_directory:
        temporary = Path(temporary_directory)
        for architecture in ("amd64", "arm64"):
            name = f"atlas-linux-{architecture}"
            if name not in assets or f"{name}.bundle" not in assets:
                raise SystemExit(f"release is missing {name} or {name}.bundle")
            binary = temporary / name
            bundle = temporary / f"{name}.bundle"
            hashes[architecture] = asset_digest(assets[name], args.repository, args.release, binary)
            asset_digest(assets[f"{name}.bundle"], args.repository, args.release, bundle)
            verify_binary_commit(binary, commit)
            verify_signature(binary, bundle)

    values = {
        "commit": commit,
        "amd64": hashes["amd64"],
        "arm64": hashes["arm64"],
    }
    replacements = {
        "Makefile": [
            (r"^(ATLAS_COMMIT\s*\?=\s*)\S+", values["commit"]),
            (r"^(ATLAS_AMD64_SHA256\s*\?=\s*)\S+", values["amd64"]),
            (r"^(ATLAS_ARM64_SHA256\s*\?=\s*)\S+", values["arm64"]),
        ],
        "Dockerfile": [
            (r"^(ARG ATLAS_COMMIT=)\S+", values["commit"]),
            (r"^(ARG ATLAS_AMD64_SHA256=)\S+", values["amd64"]),
            (r"^(ARG ATLAS_ARM64_SHA256=)\S+", values["arm64"]),
        ],
        ".github/workflows/integration.yaml": [
            (r"^(\s+commit:\s*)\S+", values["commit"]),
            (r"^(\s+amd64-sha256:\s*)\S+", values["amd64"]),
            (r"^(\s+arm64-sha256:\s*)\S+", values["arm64"]),
        ],
        ".github/workflows/cd-image-canary-release.yaml": [
            (r"^(\s+ATLAS_COMMIT=)\S+", values["commit"]),
            (r"^(\s+ATLAS_AMD64_SHA256=)\S+", values["amd64"]),
            (r"^(\s*io\.ariga\.atlas\.version=)\S+", f"dev-{values['commit']}"),
        ],
        ".github/workflows/cd-operator-release.yaml": [
            (r"^(\s+ATLAS_COMMIT=)\S+", values["commit"]),
            (r"^(\s+ATLAS_AMD64_SHA256=)\S+", values["amd64"]),
            (r"^(\s+ATLAS_ARM64_SHA256=)\S+", values["arm64"]),
            (r"^(\s*io\.ariga\.atlas\.version=)\S+", f"dev-{values['commit']}"),
        ],
    }
    updated_files = []
    for path in FILES:
        text = path.read_text(encoding="utf-8")
        for pattern, value in replacements[path.relative_to(ROOT).as_posix()]:
            text, count = re.subn(
                pattern.replace(r"\s", r"[ \t]"),
                lambda match, replacement=value: f"{match.group(1)}{replacement}",
                text,
                flags=re.MULTILINE,
            )
            if count != 1:
                raise SystemExit(f"expected one match for {pattern!r} in {path}, found {count}")
        updated_files.append((path, text))

    if not args.dry_run:
        for path, text in updated_files:
            path.write_text(text, encoding="utf-8")

    print(f"Atlas {args.repository}:{args.release} -> {commit}")
    print(f"amd64 sha256: {hashes['amd64']}")
    print(f"arm64 sha256: {hashes['arm64']}")
    if args.dry_run:
        print("dry run: no files changed")


if __name__ == "__main__":
    try:
        main()
    except urllib.error.URLError as error:
        raise SystemExit(f"could not download Atlas release asset: {error}")
