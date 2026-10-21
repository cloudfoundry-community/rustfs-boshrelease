# Changelog

All notable changes to rustfs-boshrelease are documented here.

## 0.2.0 (unreleased)

### Changed

- The release now packages upstream RustFS 1.0.3, the first general-availability line, in place of 1.0.0-beta.9. The blob is the static `linux-x86_64-musl` build, and its sha256 matches upstream's published `SHA256SUMS`.

- `rustfs.region` now reaches the server as `RUSTFS_REGION`. Before this release the job ignored the property, so the server always reported its built-in default.

- When the API uses TLS, the peer URLs in `RUSTFS_VOLUMES` use `https`, because RustFS serves internode RPC on the TLS port. A TLS cluster built with `http` peer URLs fails the handshake and never reaches quorum.

- Pre-start now assembles the TLS directory at `/var/vcap/data/rustfs-server/tls` and the job sets `RUSTFS_TLS_PATH` to it. The directory holds `rustfs_cert.pem`, `rustfs_key.pem`, and, when a CA is set, `ca.crt`. RustFS 1.0.3 refuses to start when it finds an empty `ca.crt`, so pre-start installs the CA only when it holds a certificate.

- TLS is enabled only when both `rustfs.tls.certificate` and `rustfs.tls.key` are set, and post-start uses the same test.

- `jobs/smoke-tests` signs S3 requests with AWS Signature Version 4 in place of the deprecated SigV2, which RustFS rejects with `403`. The HMAC chain is derived with `openssl` and hex-encoded with `od`, so the errand needs no `xxd` or vim-common.

- `jobs/smoke-tests` sends `HeadObject` with `curl --head` in place of `-X HEAD`. Over plaintext HTTP/1.1, `curl -X HEAD` waits for a body that never arrives and times out.

- The packaging script checks for `unzip`, requires exactly one RustFS archive and exactly one binary inside it, and runs the installed binary's `--version` so that a damaged blob fails at compile time.

- `manifests/rustfs.yml` pins bpm 1.4.22 with its bosh.io url and sha1 in place of `latest`, because bpm 1.4.31 cannot start any process on a cgroup v2 stemcell.

- `scripts/add-blob.sh` defaults to 1.0.3 and always verifies the download against upstream's `SHA256SUMS`. A missing checksum file or entry is now an error rather than a skipped check.

- The release workflow reads the RustFS version from `config/blobs.yml`, since the package spec holds only a glob. It fails when upstream's `SHA256SUMS` is missing, does not list the asset, or disagrees with the digest that `config/blobs.yml` records.

### Added

- `manifests/ops/resolute.yml` moves the deployment to the ubuntu-resolute (26.04) stemcell and pins bpm 1.4.41, the first bpm release that compiles there.

- `rustfs.tls.ca` on `rustfs-server` sets the CA that cluster peers trust. Pre-start refuses to start a multi-node TLS deployment without it.

- `rustfs.tls.certificate` on `jobs/smoke-tests` makes the errand probe the cluster over `https` when the API uses TLS. Verification is skipped with `-k`, which mirrors the `rustfs-server` job.

### Upgrade notes

- A TLS cluster now needs `rustfs.tls.ca`, and every peer's API certificate must name that peer's IP address as a subject alternative name.

- The `rustfs.peer.tls.*` properties are still accepted, but RustFS does not read the files they render.

- RustFS 1.0.3 adds `/health/live` next to `/health` and `/health/ready`, and its console answers `403` at `/` and serves the UI under `/rustfs/console/`.

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
