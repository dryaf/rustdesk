#!/usr/bin/env bash
set -euo pipefail

[[ "$(uname -s)" == Darwin ]] || { printf 'Run this script on macOS.\n' >&2; exit 1; }
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
cd "$repo_root"
arch=$(uname -m)
case "$arch" in arm64|x86_64) ;; *) printf 'Unsupported architecture: %s\n' "$arch" >&2; exit 1 ;; esac
version=$(sed -n 's/^version = "\([^"]*\)"/\1/p' Cargo.toml | head -n 1)
commit=$(git rev-parse HEAD)
app="$repo_root/flutter/build/macos/Build/Products/Release/RustDesk.app"
for binary in Contents/MacOS/RustDesk Contents/MacOS/service Contents/Frameworks/liblibrustdesk.dylib; do
    test -x "$app/$binary"
    lipo "$app/$binary" -verify_arch "$arch"
done
codesign --verify --deep --strict "$app"

release_dir="$repo_root/build/releases/macos"
mkdir -p "$release_dir"
stage=$(mktemp -d "$release_dir/.package.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
name="rustdesk-lan-$version-macos-$arch"
package="$stage/$name"
mkdir -p "$package"
ditto "$app" "$package/RustDesk.app"
cp LICENCE install-lan-macos.sh "$package/"
bash "$package/install-lan-macos.sh" --bundle "$package/RustDesk.app" --destdir "$stage/install-check"
python3 - "$package/BUILD-INFO.json" "$version" "$commit" "$arch" <<'PY'
import json, pathlib, sys
path, version, commit, arch = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
    'version': version, 'source_commit': commit, 'architecture': arch,
    'flutter_version': '3.24.5', 'rust_features': 'flutter',
    'signing': 'ad-hoc', 'notarized': False,
}, indent=2) + '\n')
PY
cat > "$package/README.txt" <<EOF
RustDesk LAN $version - macOS $arch

Extract the entire ZIP, then copy RustDesk.app to Applications and launch it.
Alternatively run: ./install-lan-macos.sh --bundle ./RustDesk.app
Connect using the other computer's private IP address.
Default ports: TCP 21118, UDP 21119 for optional LAN discovery.

The app is signed ad hoc, without Developer ID signing or Apple notarization.
macOS may require approval in System Settings > Privacy & Security to open it.
Screen Recording and Accessibility permissions are needed when hosting a session.
This build uses software video codecs. A real Mac-to-Linux remote-control session
still needs testing; the automated checks do not exercise capture or input.

Built from https://github.com/dryaf/rustdesk/tree/$commit
See LICENCE and RustDesk.app/Contents/Frameworks/App.framework/Resources/flutter_assets/NOTICES.Z
for license notices.
EOF
archive="$release_dir/$name.zip"
ditto -c -k --sequesterRsrc --keepParent "$package" "$archive"
ditto -x -k "$archive" "$stage/verify"
verified_app="$stage/verify/$name/RustDesk.app"
codesign --verify --deep --strict "$verified_app"
python3 - "$verified_app/Contents/MacOS/RustDesk" "$version" "$stage" <<'PY'
import subprocess, sys
result = subprocess.run([sys.argv[1], '--version'], cwd=sys.argv[3],
                        check=True, capture_output=True, text=True, timeout=30)
if result.stdout.strip() != sys.argv[2]:
    raise SystemExit(f'Unexpected executable version: {result.stdout!r}; stderr: {result.stderr}')
print(f'Packaged executable startup passed: {result.stdout.strip()}')
PY
(cd "$release_dir" && shasum -a 256 "$name.zip" > "$name.zip.sha256")
printf 'Built: %s\n' "$archive"
