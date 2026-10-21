# Release Process

This document covers how to cut a new final release of rustfs-boshrelease.

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
scripts/add-blob.sh 1.0.3 musl
```

Arguments:

- First argument: RustFS version tag (e.g. `1.0.3`)
- Second argument: variant — `musl` (default, statically linked) or `gnu`

The script downloads the binary from the RustFS GitHub releases, verifies its SHA256 checksum against upstream's `SHA256SUMS` file, and registers the blob in the local blob cache and `config/blobs.yml`. It refuses to register the blob when upstream publishes no checksum for it or when the checksum does not match.

Remove the previous RustFS blob with `bosh remove-blob` before you add the new one, because the package and the release workflow both expect exactly one RustFS archive.

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
3. Re-downloads the RustFS binary named in `config/blobs.yml`, verifies it against upstream's `SHA256SUMS` and the digest in `config/blobs.yml`, and re-runs `bosh upload-blobs`
4. Runs `bosh create-release --final --version X.Y.Z` to produce the release manifest
5. Runs `bosh create-release <manifest> --tarball rustfs-X.Y.Z.tgz` to produce a
   self-contained tarball
6. Computes a SHA256 checksum of the tarball
7. Commits the updated `releases/rustfs/` index back to `main`
8. Creates a GitHub Release with the tarball and checksum as attached assets

Monitor the workflow at:
`https://github.com/YOUR_ORG/rustfs-boshrelease/actions`

## Updating the RustFS Binary Version

When a new upstream RustFS version is available, follow these steps:

1. Remove the current blob with `bosh remove-blob rustfs/rustfs-linux-x86_64-musl-OLD_VERSION.zip`.

2. Run `scripts/add-blob.sh NEW_VERSION musl`.

3. Build a dev release and test it. The package spec matches the archive by a glob and the packaging script finds the binary inside it, so neither file needs editing for a version bump.

4. Update the version references in `README.md` and add a `CHANGELOG.md` entry.

5. Run `bosh upload-blobs`.

6. Create a new final release following Steps 3 to 6 above.

## Required Repository Secrets

| Secret | Description |
|--------|-------------|
| `AWS_ACCESS_KEY_ID` | S3 blobstore access key |
| `AWS_SECRET_ACCESS_KEY` | S3 blobstore secret access key |

Configure these at: `https://github.com/YOUR_ORG/rustfs-boshrelease/settings/secrets/actions`
