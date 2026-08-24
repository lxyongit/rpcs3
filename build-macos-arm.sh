#!/usr/bin/env bash

# Build and package with the same scripts used by the upstream macOS CI job.
# Override BUILD_DIR, PACKAGE_DIR or CCACHE_DIR if the defaults do not suit
# your local checkout.

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
	echo "This script must be run on an Apple Silicon Mac." >&2
	exit 1
fi

root_dir=$(cd "$(dirname "$0")" && pwd)

for command in brew git python3 pip3 wget 7z xcrun; do
	if ! command -v "$command" >/dev/null 2>&1; then
		echo "Missing required command: $command" >&2
		exit 1
	fi
done

# Keep the CI defaults explicit so a local invocation uses the same toolchain
# and Qt package as the official Apple Silicon artifacts.
export QT_VER="${QT_VER:-6.11.2}"
export QT_VER_MAIN="${QT_VER_MAIN:-6}"
export LLVM_COMPILER_VER="${LLVM_COMPILER_VER:-22}"
export RUN_UNIT_TESTS="OFF"
export BUILD_DIR="${BUILD_DIR:-build-macos-official-arm64}"
export BUILD_ARTIFACTSTAGINGDIRECTORY="${PACKAGE_DIR:-$root_dir/packages}"
export CCACHE_DIR="${CCACHE_DIR:-$root_dir/.ccache-macos-arm64}"
export RELEASE_MESSAGE="${RELEASE_MESSAGE:-$root_dir/GitHubReleaseMessage.txt}"

# The CI deploy script can omit release metadata locally. This has no effect on
# the application bundle or archive and avoids generating a checksum file.
export SKIP_RELEASE_HASH="${SKIP_RELEASE_HASH:-1}"

mkdir -p "$BUILD_ARTIFACTSTAGINGDIRECTORY"
cd "$root_dir"
exec .ci/build-mac.sh
