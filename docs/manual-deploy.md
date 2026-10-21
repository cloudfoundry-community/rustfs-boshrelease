# Manual BOSH Deployment

This guide walks through deploying the rustfs release directly with the BOSH CLI, without Genesis.

## Prerequisites

- BOSH CLI installed and targeted at a director (`bosh env` shows a healthy director)
- The rustfs release uploaded to that director
- The `bpm` release uploaded
- An Ubuntu Noble or Ubuntu Resolute stemcell uploaded (`bosh stemcells` shows it)
- Credentials for the object store S3 API (access key and secret key)

## Step 1: Upload the cloud-config

The sample cloud-config at `manifests/cloud-config.yml` provides the `rustfs` vm_type, `rustfs` disk_type, `rustfs` network, and `default` network needed by the manifest and its ops files.

Edit `manifests/cloud-config.yml` to match your IaaS before applying. The inline comments show the required `cloud_properties` for AWS, vSphere, OpenStack, and Proxmox VE.

```bash
bosh update-cloud-config manifests/cloud-config.yml
```

Verify it was accepted:

```bash
bosh cloud-config
```

## Step 2: Upload releases and stemcell

If the releases are not yet on the director, build and upload them from the release source directories:

```bash
# rustfs release
bosh create-release --force
bosh upload-release

# bpm release, pinned to the version the manifest names
bosh upload-release "https://bosh.io/d/github.com/cloudfoundry/bpm-release?v=1.4.22"
```

The manifest pins bpm 1.4.22 for Noble. On Resolute, upload bpm 1.4.41 instead, because older bpm releases do not compile there.

Upload the stemcell if not already present:

```bash
bosh upload-stemcell https://bosh.io/d/stemcells/bosh-warden-boshlite-ubuntu-noble-go_agent
# Replace with the stemcell appropriate for your IaaS and OS.
```

Confirm both releases and the stemcell appear:

```bash
bosh releases
bosh stemcells
```

## Step 3: Deploy

### Production (three nodes, `rustfs` network)

The node count is fixed at the first deploy, because RustFS cannot grow or shrink a formed cluster in place, so choose it before you deploy. A cluster needs at least three nodes.

```bash
bosh -d rustfs deploy manifests/rustfs.yml \
  --var rustfs_access_key=<your-access-key> \
  --var rustfs_secret_key=<your-secret-key>
```

### bosh-lite / single-node evaluation

The `manifests/ops/standalone.yml` ops file reduces the deployment to one instance on the `default` network, which matches bosh-lite's built-in network:

```bash
bosh -d rustfs deploy manifests/rustfs.yml \
  -o manifests/ops/standalone.yml \
  --var rustfs_access_key=<your-access-key> \
  --var rustfs_secret_key=<your-secret-key>
```

### Resolute stemcell

Add `manifests/ops/resolute.yml` to either deploy command above. It switches the stemcell to ubuntu-resolute and pins bpm 1.4.41.

```bash
bosh -d rustfs deploy manifests/rustfs.yml \
  -o manifests/ops/resolute.yml \
  --var rustfs_access_key=<your-access-key> \
  --var rustfs_secret_key=<your-secret-key>
```

Watch BOSH finish all tasks before proceeding:

```bash
bosh -d rustfs instances --vitals
```

## Step 4: Verify XFS on the persistent disk

The manifest sets `env.persistent_disk_fs: xfs`, so BOSH formats the persistent disk with XFS before mounting it at `/var/vcap/store`. Confirm the filesystem type after the deployment completes:

```bash
# df -T shows filesystem type; xfs expected for /var/vcap/store
bosh -d rustfs ssh rustfs/0 -c 'df -T /var/vcap/store'
```

Expected output contains a line like:

```
Filesystem     Type  1K-blocks    Used Available Use% Mounted on
/dev/sdb       xfs   52428800       0  52428800   0% /var/vcap/store
```

Additional verification commands:

```bash
# Show block device and mount layout
bosh -d rustfs ssh rustfs/0 -c 'lsblk'

# Confirm mount options
bosh -d rustfs ssh rustfs/0 -c 'mount | grep store'
```

## Step 5: S3 API smoke test

The rustfs-server job listens on port 9000 for the S3-compatible API. If TLS is not configured, use `http`; with TLS configured, use `https` and pass your certificate flags to curl.

```bash
# Replace <instance-ip> with the IP shown by `bosh -d rustfs instances`
curl -v http://<instance-ip>:9000/

# With TLS (adjust --cacert path or use -k for self-signed certs in dev)
curl -v --cacert /path/to/ca.crt https://<instance-ip>:9000/
```

A `403 Forbidden` or `200 OK` response from the S3 API confirms the server is running, and `curl http://<instance-ip>:9000/health/live` returns `200` once the process is up. An empty response or `Connection refused` indicates the job has not started — check logs with:

```bash
bosh -d rustfs logs rustfs/0
```

You can also run the built-in smoke-tests errand to validate basic object operations:

```bash
bosh -d rustfs run-errand smoke-tests \
  --var rustfs_access_key=<your-access-key> \
  --var rustfs_secret_key=<your-secret-key>
```
