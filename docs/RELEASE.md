# Release Process

This document covers how to cut a new final release of rustfs-boshrelease.

## Prerequisites

- `bosh` CLI installed and in `PATH` (`bosh --version`)

- S3 blobstore credentials in `config/private.yml` (see `config/private.yml.example`)

- Git configured with push access to the release repository

- GitHub repository secrets `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` set

`config/private.yml` is git-ignored, and it must contain the following.

```yaml
---
blobstore:
  provider: s3
  options:
    access_key_id: YOUR_ACCESS_KEY_ID
    secret_access_key: YOUR_SECRET_ACCESS_KEY
```

## Steps

### Step 1: Fetch the upstream RustFS binary

Run the helper script from the release root:

```bash
scripts/add-blob.sh 1.0.3 musl
```

The script takes two arguments.

- First argument
The RustFS version tag, such as `1.0.3`.

- Second argument
The variant, which is either `musl` (the default, statically linked) or `gnu`.

The script downloads the binary from the RustFS GitHub releases, verifies its SHA256 checksum against upstream's `SHA256SUMS` file, and registers the blob in the local blob cache and `config/blobs.yml`. It refuses to register the blob when upstream publishes no checksum for it or when the checksum does not match.

Remove the previous RustFS blob with `bosh remove-blob` before you add the new one, because the package and the release workflow both expect exactly one RustFS archive.

### Step 2: Upload blobs to S3

```bash
bosh upload-blobs
```

This pushes the locally cached blob to the S3 blobstore declared in `config/final.yml`, and it updates `config/blobs.yml` with the blobstore `object_id` and SHA.

### Step 3: Create the final release

```bash
bosh create-release --final --version X.Y.Z
```

Replace `X.Y.Z` with the release version, such as `0.0.1`. This version is independent of the upstream RustFS version, and we use [semantic versioning](https://semver.org/) for it.

The command does three things.

1. It finalizes all packages and jobs into `.final_builds/`.

2. It writes `releases/rustfs/rustfs-X.Y.Z.yml`, which is the release manifest.

3. It updates `releases/rustfs/index.yml`.

### Step 4: Commit release artifacts

```bash
git add config/blobs.yml releases/rustfs/rustfs-X.Y.Z.yml releases/rustfs/index.yml
git commit -m "Release X.Y.Z"
```

Do not commit `config/private.yml` or `blobs/` directory contents.

### Step 5: Tag and push

```bash
git tag vX.Y.Z
git push origin main
git push origin vX.Y.Z
```

The `vX.Y.Z` tag push triggers the CI release workflow (`.github/workflows/release.yml`).

### Step 6: CI takes over

The GitHub Actions workflow takes these steps.

1. It installs the `bosh` CLI.

2. It reconstructs `config/private.yml` from repository secrets.

3. It re-downloads the RustFS binary named in `config/blobs.yml`, verifies it against upstream's `SHA256SUMS` and the digest in `config/blobs.yml`, and re-runs `bosh upload-blobs`.

4. It runs `bosh create-release --final --version X.Y.Z` to produce the release manifest.

5. It runs `bosh create-release <manifest> --tarball rustfs-X.Y.Z.tgz` to produce a self-contained tarball.

6. It computes a SHA256 checksum of the tarball.

7. It commits the updated `releases/rustfs/` index back to `main`.

8. It creates a GitHub Release with the tarball and checksum as attached assets.

We monitor the workflow at `https://github.com/YOUR_ORG/rustfs-boshrelease/actions`.

## Updating the RustFS Binary Version

When a new upstream RustFS version is available, we follow these steps.

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

We configure these secrets at `https://github.com/YOUR_ORG/rustfs-boshrelease/settings/secrets/actions`.
