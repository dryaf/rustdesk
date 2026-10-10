#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./build-lan.sh [linux|macos] [--release|--debug] [--check|--setup]

Build the LAN-only Flutter desktop app for the current machine.
The platform defaults to the current OS; cross-compilation is not supported.

  --release  Optimized build (default)
  --debug    Debug Flutter build (macOS still needs a release Rust library)
  --check    Check prerequisites without building the app
  --setup    Install local Flutter and Debian/Ubuntu build packages, then check
  --help     Show this help

Requires Rust with rustfmt. --setup downloads Flutter 3.24.5 into build/lan-tools.
On Debian/Ubuntu, --setup uses sudo apt-get to install native build packages.
On macOS and other Linux distributions, install native dependencies separately.
See docs/LAN_ONLY.md for Linux and macOS setup commands.
Pinned bridge tools are installed into build/lan-tools if missing from PATH.
Builds can download dependencies; no app or system service is installed.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing $1. See docs/LAN_ONLY.md for setup."; }

platform=
mode=release
check_only=false
setup=false
for arg in "$@"; do
    case "$arg" in
        linux|macos)
            [[ -z "$platform" ]] || die "Choose one platform per invocation."
            platform=$arg ;;
        --debug) mode=debug ;;
        --release) mode=release ;;
        --check) check_only=true ;;
        --setup) setup=true; check_only=true ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $arg (use --help)." ;;
    esac
done

case "$(uname -s)" in
    Linux) host_platform=linux; min_rust_minor=75 ;;
    Darwin) host_platform=macos; min_rust_minor=81 ;;
    *) die "Only Linux and macOS are supported." ;;
esac
platform=${platform:-$host_platform}
[[ "$platform" == "$host_platform" ]] || die "You are on $host_platform. Run ./build-lan.sh here; run the $platform build on a $platform machine."
[[ -z "${CARGO_BUILD_TARGET:-}" ]] || die "Unset CARGO_BUILD_TARGET; this script builds for the host."

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$repo_root"
tools_dir="$repo_root/build/lan-tools"
export PATH="$tools_dir/flutter/bin:$tools_dir/bin:$PATH"
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true COCOAPODS_DISABLE_STATS=true
# The pinned bridge generator only accepts info or debug log levels.
export RUST_LOG=info
# Both native Flutter projects look for the Rust library under this directory.
export CARGO_TARGET_DIR="$repo_root/target"

if "$setup"; then
    if [[ "$platform" == linux ]] && command -v apt-get >/dev/null 2>&1; then
        packages=(build-essential git curl unzip zip xz-utils clang libclang-dev
            cmake ninja-build pkg-config nasm yasm libgtk-3-dev libxdo-dev libxfixes-dev
            libxrandr-dev libxtst-dev libxi-dev libx11-xcb-dev libxcb-randr0-dev
            libxcb-shape0-dev libxcb-xfixes0-dev libpulse-dev libpam0g-dev libdbus-1-dev
            libgbm-dev libwayland-dev wayland-protocols libxkbcommon-dev
            libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
            libvpx-dev libopus-dev libaom-dev libyuv-dev)
        if [[ "$(id -u)" == 0 ]]; then
            apt-get install --no-upgrade "${packages[@]}"
        else
            need sudo
            sudo apt-get install --no-upgrade "${packages[@]}"
        fi
        # A broken user-installed launcher can shadow the system Ninja package.
        if ! ninja --version >/dev/null 2>&1 && /usr/bin/ninja --version >/dev/null 2>&1; then
            printf 'Using /usr/bin/ninja instead of the broken Ninja on PATH.\n'
            mkdir -p "$tools_dir/bin"
            ln -s /usr/bin/ninja "$tools_dir/bin/ninja"
            hash -r
        fi
    fi
    need git
    if [[ ! -x "$tools_dir/flutter/bin/flutter" ]]; then
        [[ ! -e "$tools_dir/flutter" ]] || die "Incomplete Flutter SDK at $tools_dir/flutter; move it aside and rerun --setup."
        mkdir -p "$tools_dir"
        git clone --depth 1 --branch 3.24.5 https://github.com/flutter/flutter.git "$tools_dir/flutter"
    fi
    printf 'Using local Flutter SDK: %s\n' "$tools_dir/flutter"
fi

command -v flutter >/dev/null 2>&1 || die "Missing Flutter. Run ./build-lan.sh --setup once, then ./build-lan.sh to build on this machine."
for tool in git cargo rustc rustfmt flutter cmake pkg-config clang clang++; do
    need "$tool"
done
[[ -f libs/hbb_common/Cargo.toml ]] || die "Initialize the submodule: git submodule update --init --recursive"

rust_version=$(rustc --version | awk '{print $2}')
IFS=. read -r rust_major rust_minor _rust_patch <<< "$rust_version"
(( rust_major > 1 || (rust_major == 1 && rust_minor >= min_rust_minor) )) ||
    die "Rust 1.$min_rust_minor or newer is required on $platform (found $rust_version)."
flutter_version=$(flutter --version)
[[ "$flutter_version" == *"Flutter 3.24.5 "* ]] || die "Use Flutter 3.24.5, matching this repository's CI."

rust_host=$(rustc -vV | awk '/^host:/ {print $2}')
case "$platform:$rust_host" in
    linux:x86_64-unknown-linux-gnu) flutter_arch=x64 ;;
    linux:aarch64-unknown-linux-gnu) flutter_arch=arm64 ;;
    macos:x86_64-apple-darwin) mac_arch=x86_64; triplet=x64-osx ;;
    macos:aarch64-apple-darwin) mac_arch=arm64; triplet=arm64-osx ;;
    *) die "Unsupported native Rust host: $rust_host" ;;
esac

if [[ "$platform" == linux ]]; then
    need ninja
    ninja --version >/dev/null || die "Broken Ninja launcher on PATH. Run ./build-lan.sh --setup or fix PATH."
    for package in gtk+-3.0 libpulse dbus-1 xfixes xrandr xtst xi \
        xcb-randr xcb-shape xcb-xfixes wayland-client xkbcommon gbm vpx opus aom; do
        pkg-config --exists "$package" || die "Missing development package: $package. On Debian/Ubuntu run ./build-lan.sh --setup; otherwise see docs/LAN_ONLY.md."
    done
    # Some distributions ship libyuv headers and libraries without a .pc file.
    if ! pkg-config --exists libyuv; then
        mkdir -p "$tools_dir/pkgconfig"
        probe=$(mktemp -d "$tools_dir/libyuv-check.XXXXXX")
        trap 'rm -rf -- "$probe"' EXIT
        printf '#include <libyuv.h>\nint main(void) { return 0; }\n' |
            clang -x c - -o "$probe/check" -lyuv || die "Install libyuv development headers and library."
        cat > "$tools_dir/pkgconfig/libyuv.pc" <<'EOF'
Name: libyuv
Description: System libyuv (compiler default search paths)
Version: 0
Libs: -lyuv
EOF
        export PKG_CONFIG_PATH="$tools_dir/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    fi
    # Older libwebm headers omit this include; newer C++ compilers require it.
    export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-include cstdint"
    features=flutter,linux-pkg-config
else
    for tool in xcodebuild xcrun pod codesign; do need "$tool"; done
    xcodebuild -version >/dev/null
    xcrun --sdk macosx --show-sdk-path >/dev/null
    [[ "$(uname -m)" == "$mac_arch" ]] || die "Use Rust, Flutter and the terminal with the same native architecture."
    [[ -n "${VCPKG_ROOT:-}" ]] || die "Set VCPKG_ROOT and install the manifest dependencies (see docs/LAN_ONLY.md)."
    vcpkg_installed=${VCPKG_INSTALLED_ROOT:-$VCPKG_ROOT/installed}
    for library in vpx yuv opus aom; do
        [[ -f "$vcpkg_installed/$triplet/lib/lib$library.a" ]] ||
            die "Missing lib$library.a for $triplet. Install the vcpkg manifest dependencies."
    done
    export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-10.14}
    features=flutter
fi

printf 'Prerequisites OK: %s, Rust %s, Flutter 3.24.5.\n' "$platform" "$rust_version"
if "$check_only"; then exit 0; fi

ensure_tool() {
    local binary=$1 version=$2
    shift 2
    if command -v "$binary" >/dev/null 2>&1 && [[ "$("$binary" --version)" == "$binary $version" ]]; then
        return
    fi
    cargo install "$binary" --version "=$version" --locked --root "$tools_dir" --force "$@"
    hash -r
}

ensure_tool cargo-expand 1.0.95
ensure_tool flutter_rust_bridge_codegen 1.80.1 --features uuid

(cd flutter && flutter pub get)
flutter_rust_bridge_codegen \
    --rust-input ./src/flutter_ffi.rs \
    --dart-output ./flutter/lib/generated_bridge.dart \
    --c-output ./flutter/macos/Runner/bridge_generated.h

if [[ "$platform" == linux ]]; then
    if [[ "$mode" == release ]]; then
        cargo build --locked --lib --features "$features" --release
    else
        cargo build --locked --lib --features "$features"
    fi
    (cd flutter && flutter build linux "--$mode" --no-pub)
    bundle="$repo_root/flutter/build/linux/$flutter_arch/$mode/bundle"
    [[ -x "$bundle/rustdesk" && -f "$bundle/lib/librustdesk.so" ]] || die "Incomplete Linux bundle: $bundle"
    printf '\nBuilt: %s\nRun: %s/rustdesk\nKeep the entire bundle directory together.\n' "$bundle" "$bundle"
else
    # The Xcode project embeds target/release/liblibrustdesk.dylib in every mode.
    cargo build --locked --lib --bin service --features "$features" --release
    cp target/release/liblibrustdesk.dylib target/release/librustdesk.dylib
    (cd flutter && FLUTTER_XCODE_ARCHS="$mac_arch" FLUTTER_XCODE_ONLY_ACTIVE_ARCH=YES \
        FLUTTER_XCODE_CODE_SIGN_IDENTITY=- FLUTTER_XCODE_DEVELOPMENT_TEAM='' \
        flutter build macos "--$mode" --no-pub)
    configuration=Release
    entitlements=Release
    if [[ "$mode" == debug ]]; then configuration=Debug; entitlements=DebugProfile; fi
    app="$repo_root/flutter/build/macos/Build/Products/$configuration/RustDesk.app"
    [[ -d "$app" ]] || die "Missing macOS app: $app"
    cp target/release/service "$app/Contents/MacOS/service"
    # Adding the service invalidates the bundle signature; sign locally again.
    codesign --force --sign - "$app/Contents/MacOS/service"
    codesign --force --sign - --entitlements "flutter/macos/Runner/$entitlements.entitlements" "$app"
    codesign --verify --deep --strict "$app"
    printf '\nBuilt: %s\nLocally ad-hoc signed; no Developer ID or notarization.\n' "$app"
fi
