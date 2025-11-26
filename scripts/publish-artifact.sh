#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

PINAS_R2_BUCKET="${PINAS_R2_BUCKET:-pinas-artifacts}"
PINAS_WORKER_URL="${PINAS_WORKER_URL:-}"  # e.g. https://pinas-deployer.example.workers.dev
PINAS_WORKER_ADMIN_TOKEN="${PINAS_WORKER_ADMIN_TOKEN:-}"

usage() {
  cat <<USAGE
Usage: $0 [--version vX.Y.Z] [--dry-run]

Builds the piNAS release tarball, uploads it to the configured R2 bucket via
Wrangler, and notifies the Cloudflare Worker so clients can download it.

Environment variables:
  PINAS_R2_BUCKET            Target R2 bucket (default: pinas-artifacts)
  PINAS_WORKER_URL           Worker base URL (optional)
  PINAS_WORKER_ADMIN_TOKEN   Admin API token for the Worker (optional)
  WRANGLER_BIN               Override wrangler command (default: npx wrangler)
USAGE
}

VERSION=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

compute_version() {
  if [[ -n "$VERSION" ]]; then
    echo "$VERSION"
    return
  fi

  if git describe --tags --exact-match >/dev/null 2>&1; then
    git describe --tags --exact-match
    return
  fi

  local date_tag build_count daily_seq
  date_tag="v$(date -u +%Y.%m.%d)"
  build_count=$(git rev-list --count HEAD)
  daily_seq=$(printf "%02d" $(((build_count % 100) + 1)))
  echo "$date_tag.$daily_seq"
}

safe_sha256() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    sha256sum "$file" | awk '{print $1}'
  fi
}

file_size_bytes() {
  local file="$1"
  if stat -f%z "$file" >/dev/null 2>&1; then
    stat -f%z "$file"
  else
    stat -c%s "$file"
  fi
}

main() {
  local version pkg_dir artifact_path checksum_path object_key hash size_bytes wrangler_bin

  version="$(compute_version)"
  pkg_dir="$DIST_DIR/pinas-$version"
  artifact_path="$DIST_DIR/pinas-$version.tar.gz"
  checksum_path="$pkg_dir/CHECKSUMS.sha256"
  object_key="$version/pinas-$version.tar.gz"
  wrangler_bin="${WRANGLER_BIN:-npx wrangler}"

  echo "🚧 Building piNAS package $version"
  rm -rf "$pkg_dir"
  mkdir -p "$pkg_dir"
  mkdir -p "$DIST_DIR"

  cp -R "$REPO_ROOT/sbin" "$pkg_dir/"
  cp -R "$REPO_ROOT/boot" "$pkg_dir/" 2>/dev/null || true
  cp -R "$REPO_ROOT/scripts" "$pkg_dir/" 2>/dev/null || true
  cp -R "$REPO_ROOT/docs" "$pkg_dir/" 2>/dev/null || true
  cp -R "$REPO_ROOT/config" "$pkg_dir/" 2>/dev/null || true
  cp "$REPO_ROOT/clients.json" "$pkg_dir/" 2>/dev/null || true

  echo "$version" > "$pkg_dir/VERSION"
  echo "$TIMESTAMP" > "$pkg_dir/BUILD_DATE"
  git -C "$REPO_ROOT" rev-parse HEAD > "$pkg_dir/COMMIT_HASH"

  (cd "$pkg_dir" && find . -type f -print0 | sort -z | xargs -0 sha256sum > "$checksum_path")

  (cd "$DIST_DIR" && tar -czf "pinas-$version.tar.gz" "pinas-$version")

  hash="$(safe_sha256 "$artifact_path")"
  size_bytes="$(file_size_bytes "$artifact_path")"

  echo "📦 Artifact created: $artifact_path"
  echo "   SHA-256: $hash"
  echo "   Size: $size_bytes bytes"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "Dry run enabled – skipping upload." >&2
    return 0
  fi

  echo "☁️  Uploading to R2 bucket $PINAS_R2_BUCKET as $object_key"
  (
    cd "$REPO_ROOT/infra/cloudflare"
    $wrangler_bin r2 object put "$PINAS_R2_BUCKET/$object_key" --file "../../dist/pinas-$version.tar.gz"
  )

  if [[ -n "$PINAS_WORKER_URL" && -n "$PINAS_WORKER_ADMIN_TOKEN" ]]; then
    echo "🔔 Notifying Worker at $PINAS_WORKER_URL"
    curl -sfS -X POST "$PINAS_WORKER_URL/admin/artifacts" \
      -H "Authorization: Bearer $PINAS_WORKER_ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"version\":\"$version\",\"objectKey\":\"$object_key\",\"sha256\":\"$hash\",\"size\":$size_bytes}"
    echo
  else
    echo "ℹ️  PINAS_WORKER_URL or PINAS_WORKER_ADMIN_TOKEN missing; skipping metadata notification"
  fi

  cat <<SUMMARY

✅ piNAS $version uploaded
   Object Key : $object_key
   SHA-256    : $hash
   Size       : $size_bytes bytes

Clients will see the update after the Worker metadata is refreshed.
SUMMARY
}

main "$@"
