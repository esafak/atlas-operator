# Internal Atlas Operator Release Workflow

This repository uses `dev` as the effective main branch. The upstream
`master` branch is a synchronization source and is not a release branch.

## Dev iteration

1. Push the Atlas fork's `dev` branch. The fork publishes a mutable CLI
   `dev` release containing amd64/arm64 binaries, checksums, and Cosign
   bundles.
2. Update the operator's Atlas pin: `ATLAS_RELEASE`, `ATLAS_COMMIT`, and the
   architecture-specific hashes.
3. Push the operator's `dev` branch. The canary workflow builds and publishes:

   ```text
   ghcr.io/esafak/atlas-operator:dev
   ```

   The image embeds the verified Atlas CLI artifact and also receives a
   commit-specific image tag.
4. Internal tracking environments may consume `:dev` with Helm
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

## Internal support boundary

The internal fork targets local Kubernetes reconciliation for MySQL/MariaDB
and TiDB. Atlas Cloud CLI workflows and SQLite are outside the validated fork
image matrix. Existing operator SQLite code is not removed by this boundary.
