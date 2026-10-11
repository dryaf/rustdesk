#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./install-lan-macos.sh [--bundle DIR] [--destdir DIR]

Install the built LAN-only macOS app in /Applications/RustDesk.app.
Run as your desktop user; sudo is used when copying system files.

  --bundle DIR  Use this .app (default: native macOS release build)
  --destdir DIR Stage Applications/RustDesk.app under DIR for inspection;
                does not use sudo or change the system installation
  --help        Show this help

Build first with ./build-lan-macos.sh. Close RustDesk before updating.
Only installations owned by this installer can be replaced. If a RustDesk
host service is installed, uninstall it through the app before updating.
The signed bundle is copied intact. No service is registered or started.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

bundle=
destdir=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle|--destdir)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 needs a directory."
            if [[ "$1" == --bundle ]]; then bundle=$2; else destdir=$2; fi
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1 (use --help)." ;;
    esac
done

[[ "$(uname -s)" == Darwin ]] || die "This installer runs on macOS only."
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
bundle=${bundle:-$repo_root/flutter/build/macos/Build/Products/Release/RustDesk.app}
[[ -x "$bundle/Contents/MacOS/RustDesk" && -x "$bundle/Contents/MacOS/service" &&
    -f "$bundle/Contents/Frameworks/liblibrustdesk.dylib" &&
    -d "$bundle/Contents/Frameworks/FlutterMacOS.framework" &&
    -f "$bundle/Contents/Info.plist" ]] || die "Incomplete app: $bundle. Run ./build-lan-macos.sh first."
bundle=$(cd -- "$bundle" && pwd -P)
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")
[[ "$bundle_id" == com.carriez.rustdesk ]] || die "Unexpected app bundle identifier: $bundle_id"
codesign --verify --deep --strict "$bundle"

if [[ -n "$destdir" ]]; then
    mkdir -p -- "$destdir"
    destdir=$(cd -- "$destdir" && pwd -P)
    [[ "$destdir" != / ]] || die "--destdir must be a staging directory, not /."
else
    for plist in /Library/LaunchDaemons/com.carriez.RustDesk_service.plist \
        /Library/LaunchAgents/com.carriez.RustDesk_server.plist; do
        [[ ! -e "$plist" && ! -L "$plist" ]] || die "Uninstall the RustDesk host service through the app before installing."
    done
    if pgrep -x RustDesk >/dev/null; then die "Close RustDesk before installing."; fi
fi

applications_dir="$destdir/Applications"
app_path="$applications_dir/RustDesk.app"
# Keep installer ownership outside the bundle so its code signature stays valid.
marker="$applications_dir/.rustdesk-lan-install"
[[ ! -L "$applications_dir" ]] || die "Refusing an Applications directory symlink: $applications_dir"
[[ ! -L "$app_path" && ! -L "$marker" ]] || die "Refusing an installation symlink."
[[ ! -e "$marker" || -f "$marker" ]] || die "Invalid installation marker: $marker"
[[ "$bundle" != "$app_path" ]] || die "The source app is already at the installation path."
if [[ -e "$app_path" ]]; then
    [[ -d "$app_path" && -f "$marker" ]] || die "Another installation owns $app_path. Move it aside first."
fi

as_root() {
    if [[ -z "$destdir" && "$EUID" != 0 ]]; then sudo "$@"; else "$@"; fi
}

if [[ -z "$destdir" && "$EUID" != 0 ]]; then sudo -v; fi
as_root mkdir -p -- "$applications_dir"
stage=$(as_root mktemp -d "$applications_dir/.rustdesk-lan.XXXXXX")
trap 'as_root rm -rf -- "$stage"' EXIT
as_root ditto "$bundle" "$stage/RustDesk.app"
as_root chmod -R u=rwX,go=rX "$stage/RustDesk.app"
if [[ -z "$destdir" ]]; then as_root chown -R root:wheel "$stage/RustDesk.app"; fi
as_root codesign --verify --deep --strict "$stage/RustDesk.app"
as_root rm -rf -- "$app_path"
as_root mv -- "$stage/RustDesk.app" "$app_path"
as_root touch "$marker"
as_root chmod 644 "$marker"
printf 'Installed RustDesk LAN in %s\n' "$app_path"
if [[ -n "$destdir" ]]; then
    printf 'Staged files only.\n'
else
    printf 'Launch from Applications or run: open -a /Applications/RustDesk.app\n'
fi
