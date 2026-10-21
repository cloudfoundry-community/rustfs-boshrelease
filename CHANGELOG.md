# Changelog

All notable changes to rustfs-boshrelease are documented here.

## 0.2.1 (2026-10-21)

### Changed

- Post-start now waits until a rejoining node actually serves reads, not only until it answers `/health/ready`. RustFS 1.0.3 answers readiness from local disk-handle state, and in a rolling restart a node reported ready while GETs through it still returned 503 for several seconds. Post-start now requires that this node and every other live peer are ready, that none of them lists an entry in `details.storage.unavailableDrives`, and that an authenticated read through this node succeeds, for several checks in a row. It still passes on liveness alone when no other peer is ready, so a fresh deploy or a cold start cannot deadlock.

- A single node now waits in post-start for its own readiness and a read, bounded by `rustfs.post_start.ready_timeout_secs`.

- When reads succeed but a drive is still unavailable at the end of the ready timeout, post-start logs a warning and passes, so a degraded cluster does not fail every deploy.

- Drain now also waits until every other peer lists no unavailable drive, still bounded by `rustfs.drain.timeout_secs`.

### Added

- `bin/s3-read-probe` lists the buckets, lists one object in the first bucket, and reads that object's first byte through a given node with SigV4-signed requests built in bash. The secret key never reaches a command line. Exit 2 means that the credentials were refused or the certificate did not verify, and post-start fails at once on it.

- `rustfs.post_start.settle_checks` (default 3) sets how many checks in a row, two seconds apart, must find the node serving.

### Upgrading

- BOSH runs the drain script of the release that is already deployed, so the first roll from 0.0.1, or from any dev build without a drain script, stops each node without a drain wait, while the new post-start still holds each node until it serves reads.

## 0.2.0 (2026-10-21)

### Changed

- The release now packages upstream RustFS 1.0.3, the first general-availability line, in place of 1.0.0-beta.9. The blob is the static `linux-x86_64-musl` build, and its sha256 matches upstream's published `SHA256SUMS`.

- `rustfs.region` now reaches the server as `RUSTFS_REGION`. Before this release the job ignored the property, so the server always reported its built-in default.

- When the API uses TLS, the peer URLs in `RUSTFS_VOLUMES` use `https`, because RustFS serves internode RPC on the TLS port. A TLS cluster built with `http` peer URLs fails the handshake and never reaches quorum.

- Pre-start now assembles the TLS directory at `/var/vcap/data/rustfs-server/tls` and the job sets `RUSTFS_TLS_PATH` to it. The directory holds `rustfs_cert.pem`, `rustfs_key.pem`, and, when a CA is set, `ca.crt`. RustFS 1.0.3 refuses to start when it finds an empty `ca.crt`, so pre-start installs the CA only when it holds a certificate.

- TLS is enabled only when both `rustfs.tls.certificate` and `rustfs.tls.key` are set. Template rendering fails when only one of the two is set, and when a multi-node TLS deployment has no `rustfs.tls.ca`.

- Post-start still waits for `/health`, and then waits for `/health/ready` when at least one other peer is already ready, which means the node is rejoining a formed cluster. When no other peer is ready, as on a fresh deploy or a cold start, it passes on liveness alone so that cluster formation cannot deadlock. Every probe verifies the node against the CA by its link address instead of using `curl -k`.

- IPv6 peer addresses are bracketed in `RUSTFS_VOLUMES` and in every probe URL, and the server listens on `[::]` when any address is IPv6.

- `manifests/rustfs.yml` runs three nodes, turns off DNS link addresses, and allows ten minutes of watch time per node.

- `jobs/smoke-tests` signs S3 requests with AWS Signature Version 4 in place of the deprecated SigV2, which RustFS rejects with `403`. The HMAC chain is built in bash, hashed with `openssl` on stdin, and hex-encoded with `od -v`, so the errand needs no `xxd` or vim-common and no key appears on a command line.

- `jobs/smoke-tests` probes `/health/ready` on every peer instead of `/health`.

- `jobs/smoke-tests` sends `HeadObject` with `curl --head` in place of `-X HEAD`. Over plaintext HTTP/1.1, `curl -X HEAD` waits for a body that never arrives and times out.

- The packaging script checks for `unzip`, requires exactly one RustFS archive and exactly one binary inside it, and runs the installed binary's `--version` so that a damaged blob fails at compile time.

- `manifests/rustfs.yml` pins bpm 1.4.22 with its bosh.io url and sha1 in place of `latest`, because bpm 1.4.31 cannot start any process on a cgroup v2 stemcell.

- `scripts/add-blob.sh` defaults to 1.0.3 and always verifies the download against upstream's `SHA256SUMS`. A missing checksum file or entry is now an error rather than a skipped check.

- The release workflow reads the RustFS version from `config/blobs.yml`, since the package spec holds only a glob. It fails when upstream's `SHA256SUMS` is missing, does not list the asset, or disagrees with the digest that `config/blobs.yml` records.

### Added

- `manifests/ops/resolute.yml` moves the deployment to the ubuntu-resolute (26.04) stemcell and pins bpm 1.4.41, the first bpm release that compiles there.

- `rustfs.tls.ca` on `rustfs-server` sets the CA that cluster peers trust. Template rendering fails for a multi-node TLS deployment without it.

- A dynamic drain script on `rustfs-server` holds a node up until every other peer answers `/health/ready`. It gives up after `rustfs.drain.timeout_secs` (600 by default) and lets the stop go ahead, polling every `rustfs.drain.poll_secs`.

- `rustfs.post_start.health_timeout_secs` and `rustfs.post_start.ready_timeout_secs` bound the two post-start waits.

- `rustfs.tls.certificate` and `rustfs.tls.ca` on `jobs/smoke-tests` make the errand probe the cluster over `https` and verify every node against the CA. Without the CA, it falls back to `-k` and prints a warning.

- Template specs under `spec/jobs` run with `bundle exec rspec`.

### Upgrade notes

- A TLS cluster now needs `rustfs.tls.ca`, and every peer's API certificate must name that peer's IP address as a subject alternative name.

- The node count is fixed at the first deploy. RustFS refuses to grow a single node into a cluster, logging `unsupported pool expansion ... single-node single-drive (SNSD) ... cannot be expanded in place` to `rustfs-server.stderr.log`, and it cannot change the size of a formed cluster in place either. A cluster needs at least three nodes.

- Stopping or deleting a whole cluster can now take up to the drain bound, because the second node waits for the first. Pass `--skip-drain` when you mean to take the whole cluster down.

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
