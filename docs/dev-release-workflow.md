# Internal Atlas Operator Release Workflow

This repository uses `dev` as the effective main branch. The upstream
`master` branch is a synchronization source and is not a release branch.

## Dev iteration

1. Push the Atlas fork's `dev` branch. The fork publishes a mutable CLI
   `dev` release containing amd64/arm64 binaries, checksums, and Cosign
   bundles. The amd64 binary must be built with CGO enabled because the
   operator's host-side unit tests exercise SQLite through `go-sqlite3`.
2. Update the operator's Atlas pin: `ATLAS_RELEASE`, `ATLAS_COMMIT`, and the
   architecture-specific hashes.
3. Run `make check-atlas-pin` and the integration unit tests before pushing.
   A new Atlas artifact can change SQL output formatting even when schema
   behavior is unchanged; inspect such diffs and update narrow test assertions
   or fixtures when the new output is equivalent.
4. Push the operator's `dev` branch. The canary workflow builds and publishes:

   ```text
   ghcr.io/esafak/atlas-operator:dev
   ```

   The image embeds the verified Atlas CLI artifact and also receives a
   commit-specific image tag.
5. Internal tracking environments may consume `:dev` with Helm
   `image.pullPolicy: Always`. This tag is mutable and must not be used as a
   production pin.

The canary workflow is path-filtered. Changes that refresh the CLI pin must
touch the Dockerfile, Makefile, workflow, or another configured build path.
Note that `integration.yaml` and the release workflow are not themselves in
the canary path filter; pin refreshes qualify because the pin defaults live in
the Dockerfile and Makefile.

## Immutable promotion

1. Validate a specific Atlas fork commit and publish an immutable Atlas `v*`
   CLI release.
2. Replace the operator's CLI pin and Cosign policy with that immutable release.
3. Bump `charts/atlas-operator/Chart.yaml` `version` and `appVersion` in the
   same change. The chart version identifies the operator package; the Atlas
   CLI version identifies embedded content.
4. Push `dev`. The release workflow runs its Helm gate, then publishes the
   matching semver operator image and Helm chart to GHCR, creates the matching
   `v<operator-version>` Git tag, and creates a GitHub Release:

   ```text
   ghcr.io/esafak/atlas-operator:<operator-version>
   oci://ghcr.io/esafak/charts/atlas-operator:<operator-version>
   ```

5. Rerun image, signature, smoke, and TiDB end-to-end gates against the
   promoted artifact, then verify the published operator image contains the
   promoted CLI.

## Operator versioning

Production operator versions use the upstream operator version as their base
with a fork-qualified SemVer prerelease suffix. For example:

```text
upstream: 0.7.33
fork:     0.7.33-esafak.1
next:     0.7.33-esafak.2
```

When the upstream base moves to `0.7.34`, the fork sequence starts at
`0.7.34-esafak.1`. Do not use a fourth numeric component such as `0.7.33.1`.
The operator version identifies the chart/image; the embedded Atlas CLI release
remains independent metadata. Dev artifacts continue to use the mutable `dev`
tag rather than a production SemVer.

## Internal support boundary

The internal fork targets local Kubernetes reconciliation for MySQL/MariaDB
and TiDB. SQLite is used by host-side unit tests and therefore requires the
CGO-enabled amd64 CLI artifact, but SQLite remains outside the validated fork
production image matrix. Existing operator SQLite code is not removed by this
boundary.
