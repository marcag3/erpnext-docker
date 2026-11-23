#!/bin/bash
# Bump the version and SHA-256 pins of the binaries downloaded at build time
# (restic in the Dockerfile, s6-overlay in docker-erpnext-s6-install) to their latest
# upstream release. Run from CI before the build; idempotent when already up to date.
set -euo pipefail
cd "$(dirname "$0")/../.."

DOCKERFILE=src/variations/erpnext-nginx/Dockerfile
S6_SCRIPT=src/common/usr/local/bin/docker-erpnext-s6-install

latest_tag() {
  curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
    "https://api.github.com/repos/$1/releases/latest" | jq -er .tag_name
}

# Refuse anything that is not a SHA-256, so a changed release layout fails the run
# instead of writing garbage into a pin
check_sha() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]] || { echo "not a SHA-256: '$1'" >&2; exit 1; }
}

# --- restic: hashes come from the release's SHA256SUMS ---
tag=$(latest_tag restic/restic)
version=${tag#v}
sums=$(curl -fsSL "https://github.com/restic/restic/releases/download/${tag}/SHA256SUMS")
restic_amd64=$(awk -v f="restic_${version}_linux_amd64.bz2" '$2 == f {print $1}' <<<"$sums")
restic_arm64=$(awk -v f="restic_${version}_linux_arm64.bz2" '$2 == f {print $1}' <<<"$sums")
check_sha "$restic_amd64"
check_sha "$restic_arm64"
sed -i -E \
  -e "s/RESTIC_VERSION=[0-9.]+/RESTIC_VERSION=${version}/" \
  -e "s/(\"aarch64\" \]; then export RESTIC_SHA256=)[0-9a-f]{64}/\1${restic_arm64}/" \
  -e "s/(\"x86_64\" \]; then export RESTIC_SHA256=)[0-9a-f]{64}/\1${restic_amd64}/" \
  "$DOCKERFILE"
grep -q "RESTIC_VERSION=${version}" "$DOCKERFILE"
grep -q "$restic_amd64" "$DOCKERFILE"
grep -q "$restic_arm64" "$DOCKERFILE"

# --- s6-overlay: hashes come from the release's *.sha256 files ---
tag=$(latest_tag just-containers/s6-overlay)
s6_sha() {
  curl -fsSL "https://github.com/just-containers/s6-overlay/releases/download/${tag}/s6-overlay-$1.tar.xz.sha256" | awk '{print $1}'
}
s6_noarch=$(s6_sha noarch)
s6_x86_64=$(s6_sha x86_64)
s6_aarch64=$(s6_sha aarch64)
check_sha "$s6_noarch"
check_sha "$s6_x86_64"
check_sha "$s6_aarch64"
sed -i -E \
  -e "s/^S6_VERSION=.*/S6_VERSION=${tag}/" \
  -e "s/(x86_64 +\) S6_ARCH_SHA256=')[0-9a-f]{64}/\1${s6_x86_64}/" \
  -e "s/(aarch64 +\) S6_ARCH_SHA256=')[0-9a-f]{64}/\1${s6_aarch64}/" \
  -e "s/^(S6_NOARCH_SHA256=')[0-9a-f]{64}/\1${s6_noarch}/" \
  "$S6_SCRIPT"
grep -q "^S6_VERSION=${tag}" "$S6_SCRIPT"
grep -q "$s6_noarch" "$S6_SCRIPT"
grep -q "$s6_x86_64" "$S6_SCRIPT"
grep -q "$s6_aarch64" "$S6_SCRIPT"

git diff --stat -- "$DOCKERFILE" "$S6_SCRIPT" || true
