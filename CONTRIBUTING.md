# Contributing to rustfs-boshrelease

Thank you for contributing. This document covers the development workflow,
blob management, and release process.

## Prerequisites

- [BOSH CLI](https://bosh.io/docs/cli-v2/) v7 or later
- Ruby 3.1+ (for running specs via `rspec`)
- A BOSH director for integration testing (optional for unit specs)

## Development Setup

Clone the repository and install Ruby dependencies:

```bash
git clone https://github.com/cloudfoundry-community/rustfs-boshrelease
cd rustfs-boshrelease
bundle install
```

## Adding or Updating Blobs

Blobs are not stored in git. Download the RustFS binary and register it
with the BOSH CLI:

```bash
# Download the upstream binary
curl -Lo /tmp/rustfs-linux-x86_64-musl-1.0.0-beta.9.zip \
  https://github.com/rustfs/rustfs/releases/download/1.0.0-beta.9/rustfs-linux-x86_64-musl-v1.0.0-beta.9.zip

# Register with BOSH (updates config/blobs.yml)
bosh add-blob /tmp/rustfs-linux-x86_64-musl-1.0.0-beta.9.zip \
  rustfs/rustfs-linux-x86_64-musl-1.0.0-beta.9.zip
```

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

## Running Unit Specs

Template rendering specs live in `spec/jobs/`. Run them with:

```bash
bundle exec rspec spec/
```

Specs use `bosh-template` to render ERb templates without a running director.
Add specs when adding or modifying job templates.

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
- Include or update `spec/` tests for any template changes.
- Update `CHANGELOG.md` with a summary of changes.
- Do not commit `config/private.yml`, `blobs/`, or `.dev_builds/`.

## Code of Conduct

See [code-of-conduct.md](code-of-conduct.md).
