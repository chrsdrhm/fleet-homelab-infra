#!/usr/bin/env bash
# Installs the pinned lint tools (actionlint, tflint) into a folder and, in GitHub
# Actions, puts it on the PATH. Release binaries, checked against their published
# SHA-256 checksums. Dependabot cannot update these: bump a version and its checksum
# together by hand (the zizmor image digest is in run.sh).
# Usage: checks/install-tools.sh [DIR]   (default: $RUNNER_TEMP/bin, else ./.check-tools)
set -euo pipefail

ACTIONLINT_VERSION=1.7.12
TFLINT_VERSION=0.64.0
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    os_arch=linux_amd64
    actionlint_sha=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
    tflint_sha=cca9d13e2e1d7a2c627af60ff899a3c9b74212899416aeb96ec764d2ef954537 ;;
  Darwin-arm64)
    os_arch=darwin_arm64
    actionlint_sha=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f
    tflint_sha=2496e9cb3d24992d553b45e7c87a0fdc9449ca975233876247a9bfeda857e6c0 ;;
  *) echo "No pinned checksums for $(uname -s)-$(uname -m); install actionlint and tflint yourself." >&2; exit 1 ;;
esac

dir="${1:-${RUNNER_TEMP:+$RUNNER_TEMP/bin}}"
dir="${dir:-$PWD/.check-tools}"
mkdir -p "$dir"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
fetch() { # url, file, expected sha256
  curl -fsSLo "$work/$2" "$1"
  [ "$(sha256 "$work/$2")" = "$3" ] || { echo "Checksum mismatch for $2" >&2; exit 1; }
}

fetch "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_${os_arch}.tar.gz" actionlint.tar.gz "$actionlint_sha"
tar xzf "$work/actionlint.tar.gz" -C "$dir" actionlint
fetch "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_${os_arch}.zip" tflint.zip "$tflint_sha"
unzip -oq "$work/tflint.zip" -d "$dir"

if [ -n "${GITHUB_PATH:-}" ]; then echo "$dir" >> "$GITHUB_PATH"; fi
echo "Installed actionlint ${ACTIONLINT_VERSION} and tflint ${TFLINT_VERSION} into $dir"
