# Release Process

This document covers how to cut a new final release of rustfs-boshrelease.

> **WARNING: RustFS Distributed Mode — Under Testing**
> RustFS 1.0.0-beta.9 marks "Distributed Mode: Under Testing" in its feature matrix.
> The BOSH release enables cluster mode when instances > 1, but cluster stability,
> data durability, and node rejoin behavior have not been validated for production use.
> Use single-node mode (standalone.yml ops file) until RustFS reaches GA.

## Prerequisites

- `bosh` CLI installed and in `PATH` (`bosh --version`)
- S3 blobstore credentials in `config/private.yml` (see `config/private.yml.example`)
- Git configured with push access to the release repository
- GitHub repository secrets set: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`

`config/private.yml` is git-ignored. It must contain:

```yaml
---
blobstore:
  provider: s3
  options:
    access_key_id: YOUR_ACCESS_KEY_ID
    secret_access_key: YOUR_SECRET_ACCESS_KEY
```

## Steps

### Step 1 — Fetch the upstream RustFS binary

Run the helper script from the release root:

```bash
scripts/add-blob.sh 1.0.0-beta.9 musl
```

Arguments:

- First argument: RustFS version tag (e.g. `1.0.0-beta.9`)
- Second argument: variant — `musl` (default, statically linked) or `gnu`

The script downloads the binary from the RustFS GitHub releases, verifies its SHA256
checksum against upstream's `SHA256SUMS` file when available, and registers the blob
with the local BOSH blobstore cache (`config/blobs.yml`).

To release a new version of the binary, update `packages/rustfs/spec` and
`packages/rustfs/packaging` to reference the new version string, then re-run the script.

### Step 2 — Upload blobs to S3

```bash
bosh upload-blobs
```

This pushes the locally cached blob to the S3 blobstore declared in `config/final.yml`.
The `config/blobs.yml` file is updated with the blobstore `object_id` and SHA.

### Step 3 — Create the final release

```bash
bosh create-release --final --version X.Y.Z
```

Replace `X.Y.Z` with the release version (e.g. `0.0.1`). This version is independent
of the upstream RustFS version. Use [semantic versioning](https://semver.org/).

The command:

1. Finalizes all packages and jobs into `.final_builds/`
2. Writes `releases/rustfs/rustfs-X.Y.Z.yml` (the release manifest)
3. Updates `releases/rustfs/index.yml`

### Step 4 — Commit release artifacts

```bash
git add config/blobs.yml releases/rustfs/rustfs-X.Y.Z.yml releases/rustfs/index.yml
git commit -m "Release X.Y.Z"
```

Do not commit `config/private.yml` or `blobs/` directory contents.

### Step 5 — Tag and push

```bash
git tag vX.Y.Z
git push origin main
git push origin vX.Y.Z
```

The `vX.Y.Z` tag push triggers the CI release workflow (`.github/workflows/release.yml`).

### Step 6 — CI takes over

The GitHub Actions workflow:

1. Installs `bosh` CLI
2. Reconstructs `config/private.yml` from repository secrets
3. Re-downloads the RustFS binary and re-runs `bosh upload-blobs`
4. Runs `bosh create-release --final --version X.Y.Z` to produce the release manifest
5. Runs `bosh create-release <manifest> --tarball rustfs-X.Y.Z.tgz` to produce a
   self-contained tarball
6. Computes a SHA256 checksum of the tarball
7. Commits the updated `releases/rustfs/` index back to `main`
8. Creates a GitHub Release with the tarball and checksum as attached assets

Monitor the workflow at:
`https://github.com/YOUR_ORG/rustfs-boshrelease/actions`

## Updating the RustFS Binary Version

When a new upstream RustFS version is available:

1. Update `packages/rustfs/spec` — change the filename in `files:` to the new version
2. Update `packages/rustfs/packaging` — change the filename in the `unzip` and `cp` commands
3. Run `scripts/add-blob.sh NEW_VERSION musl`
4. Run `bosh upload-blobs`
5. Create a new final release following Steps 3–6 above

## Required Repository Secrets

| Secret | Description |
|--------|-------------|
| `AWS_ACCESS_KEY_ID` | S3 blobstore access key |
| `AWS_SECRET_ACCESS_KEY` | S3 blobstore secret access key |

Configure these at: `https://github.com/YOUR_ORG/rustfs-boshrelease/settings/secrets/actions`
