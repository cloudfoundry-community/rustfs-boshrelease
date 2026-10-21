# Contributing to rustfs-boshrelease

Thank you for contributing. This document covers the development workflow,
blob management, and release process.

## Prerequisites

- [BOSH CLI](https://bosh.io/docs/cli-v2/) v7 or later
- `unzip`, `curl`, and `sha256sum` or `shasum` for `scripts/add-blob.sh`
- A BOSH director for integration testing

## Development Setup

Clone the repository:

```bash
git clone https://github.com/cloudfoundry-community/rustfs-boshrelease
cd rustfs-boshrelease
```

## Adding or Updating Blobs

Blobs are not stored in git. The helper script downloads the RustFS binary, verifies it against upstream's `SHA256SUMS`, and registers it with the BOSH CLI, which updates `config/blobs.yml`:

```bash
scripts/add-blob.sh 1.0.3 musl
```

The package expects exactly one RustFS archive, so remove the old blob with `bosh remove-blob` before you add a new version.

To upload blobs to the S3 blobstore (requires `config/private.yml`):

```bash
cp config/private.yml.example config/private.yml
# Edit config/private.yml with valid S3 credentials
bosh upload-blobs
```

`config/private.yml` is git-ignored and must never be committed.

## Creating a Dev Release

```bash
bosh create-release --force
bosh -e <your-director> upload-release
```

## Testing Template Changes

The release has no template spec suite yet. Test template changes by building a dev release and deploying it, ideally on both a Noble and a Resolute stemcell, and then run the `smoke-tests` errand.

## Creating a Final Release

Final releases are created by CI on tag push. To create one locally:

```bash
# Populate config/private.yml with S3 credentials first
bosh create-release --final --version X.Y.Z
git add releases/ config/blobs.yml
git commit -m "Release X.Y.Z"
git tag vX.Y.Z
git push --tags
```

## Pull Request Guidelines

- Keep changes focused on a single logical concern per PR.
- Test template changes on a deployed dev release.
- Update `CHANGELOG.md` with a summary of changes.
- Do not commit `config/private.yml`, `blobs/`, or `.dev_builds/`.
