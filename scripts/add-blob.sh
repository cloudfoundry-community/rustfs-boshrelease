#!/usr/bin/env bash
# Usage: scripts/add-blob.sh [VERSION] [VARIANT]
#
# Fetch a RustFS upstream binary and register it with the BOSH blobstore.
# Must be run from the release root directory.
#
# Arguments:
#   VERSION   RustFS release tag, e.g. 1.0.3 (default: 1.0.3)
#   VARIANT   musl or gnu (default: musl; musl is statically linked, preferred)
#
# Prerequisites:
#   - bosh CLI in PATH
#   - config/private.yml populated with S3 blobstore credentials
#
# After running this script, execute:
#   bosh upload-blobs
set -e -u -o pipefail

VERSION="${1:-1.0.3}"
VARIANT="${2:-musl}"

# Validate VARIANT
if [[ "${VARIANT}" != "musl" && "${VARIANT}" != "gnu" ]]; then
  echo "ERROR: VARIANT must be 'musl' or 'gnu', got '${VARIANT}'" >&2
  exit 1
fi

# Upstream asset filename includes the 'v' prefix on the version number.
# The BOSH blob key drops the 'v' prefix for consistency with packages/rustfs/spec.
ASSET="rustfs-linux-x86_64-${VARIANT}-v${VERSION}.zip"
BLOB_KEY_FILE="rustfs-linux-x86_64-${VARIANT}-${VERSION}.zip"
BASE_URL="https://github.com/rustfs/rustfs/releases/download/${VERSION}"
URL="${BASE_URL}/${ASSET}"
SUMS_URL="${BASE_URL}/SHA256SUMS"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "==> Fetching ${URL}"
if ! curl -fL --progress-bar -o "${TMP}/${ASSET}" "${URL}"; then
  echo "ERROR: download failed — verify VERSION '${VERSION}' exists at" >&2
  echo "       https://github.com/rustfs/rustfs/releases" >&2
  exit 1
fi

# Verify the archive against upstream's SHA256SUMS.  Upstream publishes the
# file with every release, so a missing file or a missing entry stops the
# script instead of registering an unverified blob.
echo "==> Fetching ${SUMS_URL}"
if ! curl -fLs -o "${TMP}/SHA256SUMS" "${SUMS_URL}"; then
  echo "ERROR: could not download ${SUMS_URL}; refusing to add an unverified blob" >&2
  exit 1
fi
# SHA256SUMS lists the v-prefixed asset filename.
EXPECTED=$(awk -v asset="${ASSET}" '$2 == asset || $2 == "*" asset {print $1}' "${TMP}/SHA256SUMS")
if [[ -z "${EXPECTED}" ]]; then
  echo "ERROR: ${ASSET} is not listed in SHA256SUMS; refusing to add an unverified blob" >&2
  exit 1
fi
# sha256sum ships with Linux coreutils and shasum with macOS.
if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL=$(sha256sum "${TMP}/${ASSET}" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL=$(shasum -a 256 "${TMP}/${ASSET}" | awk '{print $1}')
else
  echo "ERROR: neither sha256sum nor shasum is installed" >&2
  exit 1
fi
if [[ "${EXPECTED}" != "${ACTUAL}" ]]; then
  echo "ERROR: SHA256 mismatch" >&2
  echo "  expected: ${EXPECTED}" >&2
  echo "  actual:   ${ACTUAL}" >&2
  exit 1
fi
echo "==> SHA256 OK: ${ACTUAL}"

# Register blob with BOSH blobstore under the key expected by packages/rustfs/spec.
BLOB_KEY="rustfs/${BLOB_KEY_FILE}"
echo "==> Adding blob as ${BLOB_KEY}"
bosh add-blob "${TMP}/${ASSET}" "${BLOB_KEY}"

echo ""
echo "Done. Run 'bosh upload-blobs' to push to the blobstore."
echo "Then run 'bosh create-release' or 'bosh create-release --final' as needed."
