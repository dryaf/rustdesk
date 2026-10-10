#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./install-lan.sh [--bundle DIR] [--no-pin]
       ./install-lan.sh --pin-only
       ./install-lan.sh --destdir DIR [--bundle DIR]

Install the built Linux app and pin RustDesk LAN to the current user's GNOME dock.
Run as your desktop user; sudo is used for system files when needed.

  --bundle DIR  Use this Flutter bundle (default: native Linux release bundle)
  --no-pin      Install the app without changing dock favorites
  --pin-only    Pin the already installed app, without installing files
  --destdir DIR Stage system files under DIR for inspection or packaging;
                does not use sudo or change desktop settings
  --help        Show this help

App:      /usr/local/lib/rustdesk-lan/
Command:  /usr/local/bin/rustdesk-lan
Launcher: /usr/local/share/applications/com.carriez.flutter_hbb.desktop
Service:  /etc/systemd/system/rustdesk.service

Build first with ./build-lan.sh. Close the app before reinstalling an update.
The service is installed but not started or enabled. Click Run service in the app
to start hosting and enable the service at boot.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

bundle=
destdir=
pin=true
pin_only=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle|--destdir)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 needs a directory."
            if [[ "$1" == --bundle ]]; then bundle=$2; else destdir=$2; fi
            shift 2 ;;
        --no-pin) pin=false; shift ;;
        --pin-only) pin_only=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1 (use --help)." ;;
    esac
done

[[ "$(uname -s)" == Linux ]] || die "This installer runs on Linux only."
desktop_id=com.carriez.flutter_hbb.desktop
app_path=/usr/local/lib/rustdesk-lan
command_path=/usr/local/bin/rustdesk-lan
desktop_path=/usr/local/share/applications/$desktop_id
icon_path=/usr/local/share/pixmaps/rustdesk-lan.png
service_path=/etc/systemd/system/rustdesk.service

pin_to_dock() {
    local desktop_user=()
    if [[ "$EUID" == 0 ]]; then
        [[ -n "${SUDO_USER:-}" && "${SUDO_UID:-0}" != 0 ]] || {
            printf 'Run ./install-lan.sh --pin-only as your logged-in desktop user.\n' >&2
            return 1
        }
        desktop_user=(sudo -u "$SUDO_USER" env "XDG_RUNTIME_DIR=/run/user/$SUDO_UID"
            "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$SUDO_UID/bus")
    fi
    "${desktop_user[@]}" /usr/bin/python3 - "$desktop_id" <<'PY'
import sys
import gi

gi.require_version("GioUnix", "2.0")
from gi.repository import Gio, GioUnix, GLib

desktop_id = sys.argv[1]
try:
    GioUnix.DesktopAppInfo.new(desktop_id)
except TypeError:
    sys.exit("The installed desktop entry is not visible in this desktop session.")
source = Gio.SettingsSchemaSource.get_default()
if source is None or source.lookup("org.gnome.shell", True) is None:
    sys.exit("GNOME Shell dock settings are unavailable in this session.")
try:
    Gio.bus_get_sync(Gio.BusType.SESSION, None)
except GLib.Error as error:
    sys.exit(f"Cannot reach your desktop session: {error.message}")
settings = Gio.Settings.new("org.gnome.shell")
favorites = settings.get_strv("favorite-apps")
if desktop_id not in favorites:
    if not settings.is_writable("favorite-apps"):
        sys.exit("GNOME dock favorites are locked by desktop policy.")
    if not settings.set_strv("favorite-apps", favorites + [desktop_id]):
        sys.exit("Could not update GNOME dock favorites.")
    Gio.Settings.sync()
print("RustDesk LAN is pinned to the GNOME dock.")
PY
}

if "$pin_only"; then
    [[ -z "$bundle" && -z "$destdir" && "$pin" == true ]] || die "Use --pin-only on its own."
    pin_to_dock
    exit 0
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -z "$bundle" ]]; then
    case "$(uname -m)" in
        x86_64) arch=x64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) die "Unsupported Linux architecture: $(uname -m)" ;;
    esac
    bundle="$repo_root/flutter/build/linux/$arch/release/bundle"
fi
[[ -x "$bundle/rustdesk" && -f "$bundle/lib/librustdesk.so" &&
    -f "$bundle/lib/libflutter_linux_gtk.so" && -f "$bundle/data/icudtl.dat" &&
    -d "$bundle/data/flutter_assets" ]] || die "Incomplete bundle: $bundle. Run ./build-lan.sh first."
bundle=$(cd -- "$bundle" && pwd)
[[ -f "$repo_root/res/icon.png" ]] || die "Missing res/icon.png; run the installer from the source checkout."
[[ -f "$repo_root/res/rustdesk.service" ]] || die "Missing res/rustdesk.service; run the installer from the source checkout."

as_root=()
if [[ -n "$destdir" ]]; then
    destdir=$(realpath -m -- "$destdir")
    [[ "$destdir" != / ]] || die "--destdir must be a staging directory, not /."
    pin=false
elif [[ "$EUID" != 0 ]]; then
    as_root=(sudo)
fi
install_dir=$destdir$app_path
launcher=$destdir$command_path
desktop=$destdir$desktop_path
icon=$destdir$icon_path
service=$destdir$service_path

if [[ -z "$destdir" ]]; then
    command -v systemctl >/dev/null 2>&1 || die "The Linux host service requires systemd."
fi
for unit_dir in /etc/systemd/system /usr/local/lib/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
    unit=$destdir$unit_dir/rustdesk.service
    if [[ -e "$unit" || -L "$unit" ]]; then
        if [[ -L "$unit" ]] || ! grep -qx '# RustDesk LAN installer' "$unit"; then
            die "Refusing to overwrite or shadow another service: $unit"
        fi
    fi
done

[[ ! -L "$install_dir" ]] || die "Refusing to replace an installation directory symlink: $install_dir"
if [[ -e "$install_dir" && ! -f "$install_dir/.rustdesk-lan-install" ]]; then
    die "Directory belongs to another installation: $install_dir"
fi
if [[ -e "$launcher" || -L "$launcher" ]]; then
    [[ -L "$launcher" && "$(readlink -- "$launcher")" == "$app_path/rustdesk" ]] ||
        die "Refusing to overwrite another command: $launcher"
fi
if [[ -e "$desktop" || -L "$desktop" ]]; then
    if [[ -L "$desktop" ]] || ! grep -qx 'X-RustDesk-LAN=true' "$desktop"; then
        die "Refusing to overwrite another desktop entry: $desktop"
    fi
fi

if [[ ${#as_root[@]} -gt 0 ]]; then sudo -v; fi
"${as_root[@]}" install -d -m 755 "$(dirname -- "$install_dir")" "$(dirname -- "$launcher")" \
    "$(dirname -- "$desktop")" "$(dirname -- "$icon")" "$(dirname -- "$service")"
stage=$("${as_root[@]}" mktemp -d "$(dirname -- "$install_dir")/.rustdesk-lan.XXXXXX")
trap '"${as_root[@]}" rm -rf -- "$stage"' EXIT
"${as_root[@]}" cp -a -- "$bundle/." "$stage/"
"${as_root[@]}" touch "$stage/.rustdesk-lan-install"
"${as_root[@]}" chmod -R u=rwX,go=rX "$stage"
if [[ -z "$destdir" ]]; then "${as_root[@]}" chown -R root:root "$stage"; fi
# Copy the complete replacement before removing an earlier installer-owned bundle.
"${as_root[@]}" rm -rf -- "$install_dir"
"${as_root[@]}" mv -T -- "$stage" "$install_dir"
"${as_root[@]}" ln -sfn -- "$app_path/rustdesk" "$launcher"
"${as_root[@]}" install -m 644 "$repo_root/res/icon.png" "$icon"
# Match the GTK application ID for Wayland and the window class for X11.
"${as_root[@]}" tee "$desktop" >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=RustDesk LAN
GenericName=LAN Remote Desktop
Comment=Control computers on your local network
Exec=$app_path/rustdesk
Icon=$icon_path
Terminal=false
StartupNotify=true
StartupWMClass=rustdesk
Categories=Network;RemoteAccess;
Keywords=LAN;remote;desktop;
X-RustDesk-LAN=true
EOF
"${as_root[@]}" chmod 644 "$desktop"

{
    printf '# RustDesk LAN installer\n'
    sed -e "s|/usr/bin/rustdesk|$app_path/rustdesk|" \
        -e 's|^ExecStop=pkill |ExecStop=/usr/bin/pkill |' "$repo_root/res/rustdesk.service"
} | "${as_root[@]}" tee "$service" >/dev/null
"${as_root[@]}" chmod 644 "$service"
if [[ -z "$destdir" ]]; then "${as_root[@]}" systemctl daemon-reload; fi

if command -v update-desktop-database >/dev/null 2>&1; then
    "${as_root[@]}" update-desktop-database "$(dirname -- "$desktop")"
fi
printf 'Installed RustDesk LAN in %s\n' "$install_dir"
if [[ -n "$destdir" ]]; then
    printf 'Staged files only; your system installation and dock were not changed.\n'
else
    printf 'Launch from the app menu or run: rustdesk-lan\n'
    printf 'Click Run service in the app to start hosting and enable the service at boot.\n'
    if "$pin" && ! pin_to_dock; then
        printf 'Dock pinning failed. In your desktop session run ./install-lan.sh --pin-only,\nor right-click RustDesk LAN in the app menu and select Add to Favorites.\n' >&2
        exit 1
    fi
fi
