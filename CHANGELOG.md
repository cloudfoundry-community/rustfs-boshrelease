# Changelog

All notable changes to rustfs-boshrelease are documented here.

## Unreleased

### Changed

- `jobs/smoke-tests` — sign S3 requests with AWS Signature Version 4 instead
  of the deprecated SigV2, which RustFS rejects with `403`. The HMAC chain is
  derived with `openssl` and hex-encoded with `od`, so no `xxd`/vim-common
  dependency is added.

### Added

- `jobs/smoke-tests` — `rustfs.tls.certificate` property so the errand probes
  the cluster over `https` when the API is TLS-enabled (mirrors the
  `rustfs-server` job; verification is skipped with `-k`).

## 0.0.1 (2026-05-20)

Initial pre-release scaffold of the BOSH release. Packages upstream RustFS
1.0.0-beta.3 (`linux-x86_64-musl`) and runs it under `bpm`.

### Added

- `packages/rustfs` — pre-built upstream binary blob unpacked into
  `$BOSH_INSTALL_TARGET/bin/rustfs`

- `jobs/rustfs-server` — main job; `bpm.yml.erb` enumerates peers from the
  `rustfs-peer` BOSH link to build `RUSTFS_VOLUMES`; falls back to a local
  path for single-instance deploys. `monit` delegates lifecycle to `bpm`.

- `jobs/rustfs-server/templates/bin/{pre-start,post-start,post-deploy}.erb`
  — pre-start creates the per-volume data directories on the persistent disk;
  post-start polls `/health` until the API binds; post-deploy is a no-op
  extension point.

- `jobs/rustfs-server/templates/tls/{api,peer}/*.pem.erb` — optional TLS for
  the S3 API and cluster peer mTLS; rendered from job properties.

- `jobs/smoke-tests` — BOSH errand. Probes `/health` on every peer from the
  `rustfs-peer` link, then runs `CreateBucket → PutObject → GetObject (verify) →
  DeleteObject → HeadObject (404)` against the first peer using `curl` +
  `openssl` (AWS SigV2). No external packages.

- `.github/workflows/release.yml` — tag-triggered final-release workflow with
  upstream-`SHA256SUMS` verification and GitHub Release publication.

- `scripts/add-blob.sh` — fetches a versioned RustFS asset (`musl` or `gnu`),
  verifies upstream sha256, registers under the BOSH blob key expected by
  `packages/rustfs/spec`.

- `docs/RELEASE.md` — operator-facing release process.

### Properties (highlights)

- `rustfs.access_key`, `rustfs.secret_key` — required, no defaults
- `rustfs.port` (default 9000), `rustfs.console_port` (default 9001)
- `rustfs.volumes_per_node` (default 4) — erasure-coding sub-dirs per node
- `rustfs.persistent_disk_path` (default `/var/vcap/store/rustfs`)
- `rustfs.region`, `rustfs.log_level`, `rustfs.console_enable`,
  `rustfs.health_enable`, `rustfs.server_domains`, `rustfs.kms.*`
- TLS pairs for `rustfs.tls.*` and `rustfs.peer.tls.*`

### Status

RustFS upstream is pre-release (1.0.0-beta.3) and the distributed/cluster mode
is labelled "Under Testing" by the project. This release is suitable for
evaluation; validate behaviour against your workload before relying on it for
important data.
