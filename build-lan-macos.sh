#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./build-lan-macos.sh [--release|--debug] [--check|--setup]

Build the LAN-only Flutter app for this Mac (Intel or Apple Silicon).

  --release  Optimized build (default)
  --debug    Debug Flutter UI with a release Rust library
  --check    Check prerequisites without installing dependencies or building
  --setup    Install native dependencies, local vcpkg and Flutter, then check
  --help     Show this help

Install full Xcode and Rust 1.81+ with rustfmt first. --setup requires Homebrew
and runs brew install for CocoaPods, CMake, pkg-config and LLVM. It downloads
the pinned vcpkg checkout and NASM 2.16.03 (Intel only) into build/lan-tools.
An explicit VCPKG_ROOT uses your existing pinned checkout instead.
Setup checks prerequisites; run this script again without --setup to build.
The app is signed ad hoc for local use. No app or service is installed.
Install the finished app with ./install-lan-macos.sh.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing $1. See docs/LAN_ONLY.md#macos-prerequisites."; }

setup=false
for arg in "$@"; do
    case "$arg" in
        --setup) setup=true ;;
        --check|--release|--debug) ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $arg (use --help)." ;;
    esac
done

[[ "$(uname -s)" == Darwin ]] || die "Run this script on macOS."
[[ -z "${CARGO_BUILD_TARGET:-}" ]] || die "Unset CARGO_BUILD_TARGET; this script builds for the host."
case "$(uname -m)" in
    x86_64) triplet=x64-osx; rust_host=x86_64-apple-darwin ;;
    arm64) triplet=arm64-osx; rust_host=aarch64-apple-darwin ;;
    *) die "Unsupported Mac architecture: $(uname -m)" ;;
esac

for tool in xcodebuild xcrun; do need "$tool"; done
if ! xcodebuild -version >/dev/null 2>&1; then
    if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
        die "Select Xcode with sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer, then finish setup with sudo xcodebuild -runFirstLaunch."
    fi
    die "Full Xcode was not found at /Applications/Xcode.app. Install a compatible version from https://developer.apple.com/download/all/ and open it once. If installed elsewhere, select its Contents/Developer directory. See docs/LAN_ONLY.md#macos-prerequisites."
fi
xcrun --sdk macosx --show-sdk-path >/dev/null

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cd "$repo_root"
tools_dir="$repo_root/build/lan-tools"
export PATH="$tools_dir/bin:${HOME}/.cargo/bin:$PATH"
export VCPKG_ROOT=${VCPKG_ROOT:-$tools_dir/vcpkg}
export VCPKG_DEFAULT_TRIPLET=$triplet VCPKG_DEFAULT_HOST_TRIPLET=$triplet
export COCOAPODS_DISABLE_STATS=true

if "$setup"; then
    for tool in brew git cargo rustc rustfmt curl unzip; do need "$tool"; done
    [[ "$(rustc -vV | awk '/^host:/ {print $2}')" == "$rust_host" ]] ||
        die "Use Rust and the terminal with the same native architecture."
    brew install cocoapods cmake pkg-config llvm
    git submodule update --init --recursive
    mkdir -p "$tools_dir/bin"

    if [[ "$triplet" == x64-osx ]]; then
        if ! command -v nasm >/dev/null 2>&1 || [[ "$(nasm --version)" != 'NASM version 2.16.'* ]]; then
            archive="$tools_dir/nasm-2.16.03-macosx.zip"
            curl --fail --location --retry 3 --output "$archive" \
                https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/macosx/nasm-2.16.03-macosx.zip
            unzip -oq "$archive" -d "$tools_dir"
            install -m 755 "$tools_dir/nasm-2.16.03/nasm" "$tools_dir/bin/nasm"
            hash -r
        fi
    fi

    vcpkg_commit=$(sed -n 's/.*"baseline": "\([^"]*\)".*/\1/p' vcpkg.json)
    [[ -n "$vcpkg_commit" ]] || die "Missing vcpkg baseline in vcpkg.json."
    if [[ ! -e "$VCPKG_ROOT" ]]; then
        git clone https://github.com/microsoft/vcpkg.git "$VCPKG_ROOT"
        git -C "$VCPKG_ROOT" checkout --detach "$vcpkg_commit"
    fi
    [[ "$(git -C "$VCPKG_ROOT" rev-parse HEAD)" == "$vcpkg_commit" ]] ||
        die "VCPKG_ROOT must use commit $vcpkg_commit. Select a matching checkout."
    if [[ ! -x "$VCPKG_ROOT/vcpkg" ]]; then
        "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
    fi
fi

if [[ -z "${LIBCLANG_PATH:-}" ]] && command -v brew >/dev/null 2>&1; then
    llvm_prefix=$(brew --prefix llvm)
    if [[ -d "$llvm_prefix/lib" ]]; then export LIBCLANG_PATH="$llvm_prefix/lib"; fi
fi

if "$setup"; then
    "$VCPKG_ROOT/vcpkg" install --triplet "$triplet" \
        --x-install-root="${VCPKG_INSTALLED_ROOT:-$VCPKG_ROOT/installed}"
elif [[ "$triplet" == x64-osx ]]; then
    need nasm
    [[ "$(nasm --version)" == 'NASM version 2.16.'* ]] ||
        die "Intel codec builds need NASM 2.16.x. Run ./build-lan-macos.sh --setup."
fi

exec "$repo_root/build-lan.sh" macos "$@"
