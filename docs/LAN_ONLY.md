# LAN-only build

The supported workflow is a Linux host and a macOS client, both built from this
source. Start the Linux service, configure its password, and enter its private IP
on the Mac. The default remote desktop port is TCP 21118; optional discovery uses
UDP broadcast on port 21119. No rendezvous or relay server is needed.

## Building

Run the Bash script from this checkout on each target machine. It supports Linux
and macOS on x86_64 and ARM64, using the current machine's architecture. It builds
the Flutter app, generates its Rust bridge, and prints the finished bundle path.

On your Linux computer, run:

```bash
./build-lan.sh --setup         # install Flutter and Debian/Ubuntu build packages
./build-lan.sh                 # release build for this computer
```

On your Mac, install the native prerequisites below, then run these same two
commands in the Mac's checkout. Do not run `./build-lan.sh macos` on Linux;
cross-compilation is not supported. `--check` checks prerequisites without
installing packages, and `--debug` builds a debug UI.

Setup downloads Flutter **3.24.5** into `build/lan-tools/flutter`. Future script
invocations find it automatically, so no shell-profile or `PATH` edit is needed.
On Debian/Ubuntu, setup uses `sudo apt-get install` for native dependencies and
may ask for your sudo password and apt confirmation in your terminal. It does not
install native dependencies on other Linux distributions or macOS. An existing
Flutter **3.24.5** on `PATH` also works without running setup.

Install Rust with the `rustfmt` component. The repository's CI uses Rust
**1.75.0** for Linux and **1.81.0** for macOS. With rustup, select the corresponding
version through `RUSTUP_TOOLCHAIN`, for example:

```bash
rustup toolchain install 1.75.0 --component rustfmt  # use 1.81.0 on macOS
export RUSTUP_TOOLCHAIN=1.75.0                     # use 1.81.0 on macOS
git submodule update --init --recursive
```

The script installs missing or mismatched `cargo-expand` **1.0.95** and
`flutter_rust_bridge_codegen` **1.80.1** into the ignored `build/lan-tools`
directory. Rust, Flutter, CocoaPods, and vcpkg may download build dependencies;
the runtime LAN restriction does not make the build process offline. The script
installs system packages only with `--setup`; it does not launch the app or
install a service. Cargo uses the committed lockfile; `flutter pub get` may update
`flutter/pubspec.lock` to match the pinned SDK. Generated bridge files are ignored
build artifacts.

### Linux prerequisites

On Debian/Ubuntu, `./build-lan.sh --setup` installs the native toolchain and
development libraries. To install them manually instead:

```bash
sudo apt-get install build-essential git curl unzip zip xz-utils clang libclang-dev \
  cmake ninja-build pkg-config nasm yasm libgtk-3-dev libxdo-dev libxfixes-dev \
  libxrandr-dev libxtst-dev libxi-dev libx11-xcb-dev libxcb-randr0-dev \
  libxcb-shape0-dev libxcb-xfixes0-dev libpulse-dev \
  libpam0g-dev libdbus-1-dev libgbm-dev libwayland-dev wayland-protocols \
  libxkbcommon-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  libvpx-dev libopus-dev libaom-dev libyuv-dev
./build-lan.sh linux
```

Other distributions need equivalent development packages. The script uses system
codecs via `linux-pkg-config`; it supplies local pkg-config metadata if the
distribution's libyuv package omits it. Keep the complete output directory
`flutter/build/linux/<x64|arm64>/<release|debug>/bundle/` together and run its
`rustdesk` executable. This is a desktop bundle, not a `.deb` or AppImage. The
Linux host needs the corresponding runtime libraries on the destination system.

### macOS prerequisites

The macOS entry point automates native dependency setup using Homebrew. Install
full Xcode from the Mac App Store or [Apple's downloads](https://developer.apple.com/download/all/),
choosing a version compatible with your macOS. Place it in `/Applications`, open
it once, and complete its first-launch setup. The standalone Command Line Tools
are insufficient for this Flutter app. After `/Applications/Xcode.app` exists,
select and initialize it:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
xcodebuild -version
```

If Xcode has a different name or location, use its actual `Contents/Developer`
path. `xcode-select --switch` selects an installed Xcode; it does not install
Xcode. Then install Rust 1.81 or newer with rustfmt and run:

```bash
./build-lan-macos.sh --setup
./build-lan-macos.sh
./install-lan-macos.sh
```

`--setup` installs CocoaPods, CMake, pkg-config and LLVM with Homebrew,
initializes submodules, downloads Intel NASM 2.16.03 if needed, and prepares the
pinned vcpkg dependencies and Flutter SDK. Downloads live in `build/lan-tools`;
later invocations find them automatically. An explicit `VCPKG_ROOT` is respected
and must match the manifest's baseline commit. `--check`, `--release` and
`--debug` have the same behavior as `build-lan.sh`. The Mac entry point invokes
that existing script for bridge generation, compilation and ad-hoc signing.

To prepare the dependencies manually for `./build-lan.sh macos` instead:

Install full Xcode, select it as the active developer directory, and complete its
first-launch setup. Install CocoaPods, CMake, pkg-config, and LLVM (for libclang);
for example with Homebrew:

```bash
brew install cocoapods cmake pkg-config llvm
export LIBCLANG_PATH="$(brew --prefix llvm)/lib"
```

Use Rust, Flutter, the terminal, and native dependencies of the same architecture.
For Intel codec builds, put NASM **2.16.x** on `PATH`, as in this repository's CI;
NASM 3.x is incompatible with the pinned codec sources. Set up the pinned vcpkg
checkout once, then install this repository's manifest from the repository root:

```bash
git clone https://github.com/microsoft/vcpkg.git ../rustdesk-vcpkg
git -C ../rustdesk-vcpkg checkout 9e593bb18ea69cc5095e012465dcd675a822ed0d
export VCPKG_ROOT="$(cd ../rustdesk-vcpkg && pwd)"
"$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
triplet=arm64-osx
if [ "$(uname -m)" = x86_64 ]; then triplet=x64-osx; fi
"$VCPKG_ROOT/vcpkg" install --triplet "$triplet" \
  --x-install-root="$VCPKG_ROOT/installed"
./build-lan.sh macos
```

The output is `flutter/build/macos/Build/Products/Release/RustDesk.app`
(`Debug` for `--debug`). The service helper is included and the bundle is signed
ad hoc for local use; distribution signing, notarization, and DMG creation are not
performed. macOS always builds the Rust library in release mode because the
existing Xcode project requires that path, even for a debug Flutter app.

### macOS CI builds

`.github/workflows/lan-macos.yml` runs separate Apple Silicon (`macos-15`) and
Intel (`macos-15-intel`) jobs using Xcode 16.4, Rust 1.81.0, Flutter 3.24.5, and
the pinned vcpkg checkout. It prepares software codecs, applies the upstream
Flutter compatibility patches, and invokes `build-lan-macos.sh --release`.
Each job runs the Rust LAN regression tests and Flutter network-policy tests.

`.github/scripts/package-lan-macos.sh` verifies the native architecture and app
signature, then creates a ZIP with the full app, installer, license, and source
metadata. It extracts the ZIP, verifies the signature again, and checks executable
startup with `--version`. ZIPs and SHA-256 checksums are uploaded as Actions
artifacts named `rustdesk-lan-macos-arm64` and `rustdesk-lan-macos-x86_64`.
These apps are signed ad hoc without Developer ID signing or notarization; macOS
may require approval in Privacy & Security. A real Mac-to-Linux session still
needs testing. Push a change to its workflow,
packaging script, or Bash build scripts on `lan-only` to trigger both builds.

Regression surface for macOS CI: the workflow and packaging script are new files.
Only `README.md` and this document change among existing files, to explain how
to obtain the builds. Existing application runtime and local build paths are used
without modification.

### Windows x86_64

The dedicated `.github/workflows/lan-windows.yml` builds on Windows Server 2022
with Visual Studio, Rust 1.75.0, Flutter 3.24.5, LLVM 15, and the pinned vcpkg
checkout. It installs only the software codec dependencies and applies the same
Flutter SDK patch and Windows engine replacement as the upstream Windows build.
Bridge generation uses cargo-expand 1.0.95 and flutter_rust_bridge_codegen 1.80.1.

With those prerequisites and `VCPKG_ROOT` configured on Windows, run
`./build-lan-windows.ps1` in PowerShell 7. The script generates the bridge, builds
the Rust and Flutter components, runs the LAN tests, and creates a ZIP plus a
SHA-256 checksum under `build/releases/windows/`. Extract the entire ZIP and run
`rustdesk.exe`; its DLLs and `data` directory must remain beside it.

This is an unsigned x86_64 build using software video codecs. Optional printer
and virtual-display drivers and the topmost-window privacy helper are not bundled.
Windows LAN address enumeration reads local adapter information through
`GetAdaptersAddresses`; it does not probe public addresses. Windows discovery
replies currently omit the MAC address used for wake-on-LAN. Interactive desktop
capture and input still require testing on a real Windows PC.

## Installing on Ubuntu

After `./build-lan.sh` has produced the Linux release bundle, run this in your
logged-in Ubuntu desktop terminal:

```bash
./install-lan.sh
```

The installer asks for sudo to copy system files, then pins **RustDesk LAN** for
your desktop user. It preserves your other favorites and does not add duplicates
when rerun. Running the script itself with `sudo` also pins for the original
sudo user. The installed bundle is independent of the source checkout.

| Installed item | Location |
| --- | --- |
| App, libraries, and Flutter assets | `/usr/local/lib/rustdesk-lan/` |
| Command | `/usr/local/bin/rustdesk-lan` |
| Desktop entry | `/usr/local/share/applications/com.carriez.flutter_hbb.desktop` |
| Icon | `/usr/local/share/pixmaps/rustdesk-lan.png` |
| systemd service | `/etc/systemd/system/rustdesk.service` |

The desktop filename matches the application's Wayland ID; `StartupWMClass`
matches its X11 window class. The `/usr/local` app path also satisfies the app's
existing installed-location check. Launch from the dock/app menu or run
`rustdesk-lan`. The installer registers the systemd service using the installed
LAN executable. It does not start or enable it. Click **Run service** in the app
to start hosting and enable the service at boot, then configure your password.
Linux host installation requires systemd.

If an earlier installation reports `Unit rustdesk.service does not exist`, close
the app and rerun `./install-lan.sh --no-pin`, then reopen it and click **Run
service**. No rebuild is needed; the earlier installer omitted the service unit.

Close the app before reinstalling an updated build. Rerun `./install-lan.sh` to
replace an earlier installer-owned bundle, including removing stale bundled
files. Conflicting commands, installation directories, desktop entries, or
systemd units are rejected rather than overwritten. User configuration is stored
separately and is not copied or removed by this installer.

Options:

- `--bundle DIR`: install another complete Flutter bundle, such as
  `flutter/build/linux/x64/debug/bundle`.
- `--no-pin`: install without editing desktop favorites.
- `--pin-only`: retry dock pinning in your desktop session after installation.
- `--destdir DIR`: stage the system files under a directory for inspection or
  packaging, without sudo or desktop-setting changes.

Automatic pinning uses Ubuntu's system Python with PyGObject/GioUnix and GNOME
Shell settings. If it fails, the files remain installed and the script prints
instructions to retry or select **Add to Favorites** from the app menu. Actual
system installation requires sudo authentication in your terminal.

## Installing on macOS

After building on your Mac, run `./install-lan-macos.sh` as your desktop user.
It asks for sudo to copy the complete signed bundle to
`/Applications/RustDesk.app`. Open RustDesk from Applications or run
`open -a /Applications/RustDesk.app` and enter the Linux host's private IP.

The installer verifies the bundle signature before copying and after staging.
It records ownership in `/Applications/.rustdesk-lan-install`, outside the
signed bundle. Rerunning it replaces an earlier installer-owned app and removes
stale bundled files. It refuses an unrelated existing RustDesk app or installation
symlink. Move an unrelated installation aside manually first. User configuration
is kept separately and is not copied or removed by this installer.

Close RustDesk before updating. If the Mac has a RustDesk host service, uninstall
that service through the app first; this client installer does not manage
launchd jobs. It does not register or start a service or change Dock settings.
The app is signed ad hoc for local use, without Developer ID signing or
notarization. macOS may request confirmation when opening a copied build.

Options:

- `--bundle DIR`: install another complete `.app`, including a debug build.
- `--destdir DIR`: stage `Applications/RustDesk.app` and the ownership marker
  under DIR without sudo, launching the app, or changing the system installation.

## Network boundary

- Outgoing sessions parse IP literals before creating a direct TCP socket. They
  never resolve names or use the configured SOCKS/HTTP proxy.
- Settings validation uses the same literal parser, including the legacy UI.
  Interface enumeration on Linux/macOS uses the OS interface list. The
  `default-net` dependency that sent gateway probes to `1.1.1.1` was removed.
- Accepted addresses are IPv4 RFC 1918, IPv4 link-local, IPv6 unique-local,
  IPv6 link-local, and loopback. IPv4-mapped IPv6 addresses receive the IPv4 check.
  Unspecified, multicast, limited-broadcast, and public destinations are rejected.
- The host checks incoming remote desktop and discovery source addresses too.
  Authentication, approval prompts, permissions, and the existing direct TCP
  session protocol remain in place.
- Both port-forwarding implementations enforce the same destination policy.
- The native HTTP implementation, server registration, relay negotiation,
  NAT/STUN probes, account synchronization, downloads, recording upload, and
  Telegram transport have been removed. The Flutter HTTP entry point reports an
  unsupported-operation error. Remote avatar images are not fetched. URL launches
  accept local `file:` URLs only.
- The WebRTC feature is no longer enabled. The shared `hbb_common` submodule is
  unchanged; its generic transports and server constants have no external
  connection path in this application. Build dependency URLs and documentation
  links remain. Building may require Internet access to fetch dependencies.
- This audit covers the native Linux/macOS apps. Separate web-client sources
  and general-purpose networking code in shared dependencies still exist in the
  repository; this is not a claim that every external URL or networking helper
  has been deleted from the whole tree. The web-only Google Fonts path is not
  executed by the native apps.
- Small inert or error-returning entry points remain for the generated UI bridge
  and existing callers. There is no switch that restores the removed transports.

## Known limits

- This is an address-based restriction. Private addresses routed through a VPN
  are also accepted; globally routable addresses on a local network are rejected.
- Enter IP literals rather than `.local` names. Scoped IPv6 addresses can use a
  numeric interface index, for example `[fe80::1%3]:21118`.
- Discovery is IPv4 broadcast and finds hosts on the same broadcast domain. Use a
  literal address across private subnets, for IPv6, or with a custom host port.
- The desktop displays the first eligible IPv4 address. On a machine with several
  interfaces, select the address reachable from the other computer.
- Previously saved server IDs cannot connect. Refresh discovery or enter the IP
  directly. Account address books and remote online-status queries are unavailable.
- Some legacy dialogs and generated API names remain for compatibility; invoking
  a removed service cannot initiate an HTTP request.
- macOS builds and an actual Mac-to-Linux session must be checked on those systems.
- Interface enumeration and the displayed LAN address are implemented on Linux,
  macOS, and Windows; other operating systems are outside this variant's scope.

## Regression surface

Every existing file changed below is needed either to remove external networking,
enforce the LAN boundary, or make the retained direct connection usable.

| Existing files | Changed runtime path and reason |
| --- | --- |
| `Cargo.toml`, `Cargo.lock` | Remove the app HTTP/STUN and probing `default-net` dependencies, stop enabling WebRTC, and use the existing `nix` crate for passive Linux/macOS interface enumeration. |
| `src/lib.rs` | Wire in the address policy module. |
| `src/client.rs` | Replace server-mediated connection establishment with literal LAN TCP; remove relay, NAT, ICE and server online-status traffic. |
| `src/rendezvous_mediator.rs` | Retain direct listening and discovery; remove registration and relay handling; expose listener readiness. |
| `src/server.rs` | Remove server-side relay and punched-connection setup. |
| `src/lan.rs` | Restrict discovery replies to LAN sources, use their observed IP as the connection destination, and enumerate local interfaces without public gateway probes for discovery and wake-on-LAN. |
| `src/server/connection.rs`, `src/server/port_forward_mux.rs` | Validate forwarding destinations before either implementation opens a socket. |
| `src/common.rs` | Remove NAT, HTTP, update and server probes; expose no API server; enforce direct-address recognition and hide unavailable settings. |
| `src/auth_2fa.rs` | Remove Telegram delivery while retaining local TOTP. |
| `src/hbbs_http.rs`, `src/hbbs_http/account.rs`, `src/hbbs_http/downloader.rs`, `src/hbbs_http/http_client.rs`, `src/hbbs_http/record_upload.rs`, `src/hbbs_http/sync.rs` | Remove HTTP transport and service workers; retain compatibility responses only. |
| `src/server/video_service.rs` | Remove recording-upload hookup while retaining local recording. |
| `src/updater.rs` | Remove network update implementation; retain local active-session checks used by macOS installation. |
| `src/ipc.rs` | Report LAN listener readiness instead of registration-server status. |
| `src/ui_interface.rs`, `src/flutter_ffi.rs` | Display a usable LAN address without gateway probes, make direct access permanent, reject registration/deployment, hide accounts/address books, and validate settings without DNS. |
| `src/ui.rs`, `src/ui/index.tis` | Remove browser launches and Sciter's independent downloader. |
| `flutter/lib/utils/http_service.dart`, `flutter/lib/common.dart` | Remove Dart HTTP dispatch and remote avatar loading. |
| `flutter/lib/desktop/pages/connection_page.dart`, `flutter/lib/desktop/pages/desktop_home_page.dart`, `flutter/lib/desktop/pages/desktop_setting_page.dart`, `flutter/lib/common/widgets/peer_card.dart` | Present LAN addressing and remove update, Telegram, NAT and relay controls. |
| `flutter/lib/common/widgets/address_book.dart`, `flutter/lib/common/widgets/login.dart`, `flutter/lib/common/widgets/toolbar.dart`, `flutter/lib/desktop/pages/install_page.dart`, `flutter/lib/desktop/widgets/update_progress.dart`, `flutter/lib/mobile/pages/connection_page.dart`, `flutter/lib/mobile/pages/settings_page.dart` | Route existing URL entry points through the local-file-only launcher. The desktop pages and `common.dart` listed above use that launcher too. |
| `README.md` | Document the LAN-only workflow, build entry point, and distinction from upstream binaries. |

New files contain the address policy (`src/lan_only.rs`), local-file-only URL
launcher (`flutter/lib/utils/local_url.dart`), Flutter network-policy tests
(`flutter/test/lan_network_policy_test.dart`), the standalone native build script
(`build-lan.sh`), and this document. The build-script addition changes only
`README.md` and this document among existing files; it changes no app runtime
paths or existing build scripts.

The setup follow-up changes only `build-lan.sh`, `README.md`, and this document.
It adds checkout-local Flutter discovery, explicit dependency installation, and
actionable prerequisite errors to address the missing-Flutter build failure.
It also selects the system Ninja when a broken launcher shadows it. App runtime
paths are unaffected.

The installer addition introduces only `install-lan.sh` and installation
instructions in `README.md` and this document. It copies the existing Linux
bundle, registers a desktop launcher, and updates the desktop user's GNOME
favorites. No Rust/Flutter runtime paths or existing build scripts change.

The missing-service fix changes `install-lan.sh` to register the existing service
template with the installed LAN executable path and reload systemd. This is
necessary because **Run service** enables and starts `rustdesk.service`.
`README.md` and this document now describe service setup and repair. The app's
Rust/Flutter service-control paths and the shared service template are unchanged.

## Verification

Windows build regression surface: `Cargo.toml` enables three Windows API binding
features; `src/platform/windows.rs` declares the new Windows-only LAN module;
`src/lan.rs` routes Windows interface enumeration to it. These changes provide
the LAN IP display and interface selection on Windows. Linux/macOS enumeration
keeps its existing path. The Windows implementation, build script, and workflow
are new files; `README.md` and this document describe the build and its limits.
`src/client.rs` restores the trait import needed to compile its existing non-Linux
audio backend; the audio implementation itself is unchanged.

Rechecked on 2026-10-10:

- Missing-service repair: `bash .github/scripts/test-lan-installer.sh` failed on
  the earlier installer because the unit was missing, then passed all three
  checks with the fix: unit installation, reinstallation, and preservation of
  an unrelated service. Bash syntax, ShellCheck, `desktop-file-validate`, and
  `systemd-analyze verify` passed. The live host confirmed `LoadState=not-found`;
  applying the repair requires interactive sudo authentication.
- Native Linux check: `cargo check --offline --features linux-pkg-config --tests`.
- Flutter-enabled Rust check:
  `cargo check --offline --features flutter,linux-pkg-config --tests`.
- Native Rust tests:
  `cargo test --offline --lib --features linux-pkg-config -- --test-threads=1 --skip platform::tests::`:
  **271 passed, 0 failed, 3 ignored, 3 filtered out**. The three filtered tests
  capture the desktop cursor or change screen resolution. The ignored tests
  are the project's extended video quality simulations.
- The same Rust suite with `--features flutter,linux-pkg-config` passed
  **273 tests, 0 failed**, with the same three ignored and three filtered tests.
- Five focused Rust LAN tests passed under `strace -f -e trace=network`:
  literal address acceptance/rejection, HTTP rejection, settings validation,
  and local interface enumeration. No IP destination or DNS request was seen;
  enumeration used local kernel netlink calls.
- Flutter 3.24.5: `flutter analyze --no-pub` reported **no issues**;
  `flutter test --no-pub` passed **134 tests**, including HTTP/URL rejection.
- Both the native executable and Flutter Rust library built. The complete
  Linux desktop debug bundle built with `flutter build linux --debug --no-pub`:
  `flutter/build/linux/x64/debug/bundle/rustdesk`.
- The new `./build-lan.sh linux --debug` completed bridge generation, the Rust
  build, and the Linux Flutter bundle build. `bash -n` and ShellCheck 0.11.0
  passed. Invalid arguments, cross-platform requests, prerequisite checks, and
  the missing-libyuv-metadata fallback were checked. macOS Intel/debug and
  ARM64/release command flows were exercised with temporary stub tools only;
  actual macOS compilation and signing remain unverified.
- Setup follow-up: Bash syntax and ShellCheck passed. Temporary stub tools
  exercised missing-Flutter diagnostics, Linux setup with a broken Ninja
  launcher, and macOS setup; subsequent checks found the local SDK without
  `PATH` edits. The real SDK was copied from the verified temporary installation
  into `build/lan-tools/flutter`, and the real prerequisite check passed using
  the extracted development libraries. An APT dry run resolved all requested
  packages (65 new packages, no upgrades or removals). Actual system package
  installation still requires the user's sudo authentication.
- Linux installer: Bash syntax, ShellCheck, and `desktop-file-validate` passed.
  A staged release installation preserved every bundle file, applied read-only
  group/other permissions, and ran `rustdesk --version` successfully (`1.5.0`).
  Reinstallation removed stale files; invalid inputs and conflicting commands
  or installation directories were rejected without overwriting them. Two
  `--pin-only` runs against an isolated D-Bus/dconf session preserved existing
  GNOME favorites and added exactly one RustDesk LAN entry. System files and
  the real user's dock were not changed during these checks; a live dock icon
  has not been visually verified.
- An isolated host smoke test started the real LAN mediator, received a TCP
  authentication challenge, and obtained a UDP discovery reply. Its network
  trace contained only loopback IP destinations plus local Unix/netlink calls.
  The temporary smoke-test source was removed after verification.

The smoke test does not establish an authenticated desktop session. Its finite
trace is evidence for those exercised paths, not proof of every possible runtime
behavior. The source audit found no remaining reachable external-service
transport in the native app paths inspected.

This workstation's missing development headers were downloaded and extracted
under `/tmp`, without installing system packages. The check used that pkg-config
path and the include path for those headers. `CXXFLAGS='-include cstdint'` was
needed for the existing libwebm dependency with this workstation's compiler.

For this recheck the pinned Flutter SDK, pub cache, bridge generator 1.80.1,
and cargo-expand 1.0.95 were installed under `/tmp`. The normal bridge-generation
workflow completed; generated bridge files remain ignored build artifacts.
SDK-dependent pub lockfile churn was reverted. The generated CMake cache was
pointed at `/usr/bin/ninja` because the user's Python Ninja launcher was broken.
No system packages were installed. macOS compilation and a live Mac-to-Linux
remote-control session remain unverified.

For an end-to-end check, build this source on both machines, connect from the Mac
to the Linux private IP, authenticate, and verify video, keyboard, mouse, and
clipboard. Repeat with Internet access blocked while allowing LAN traffic. A
public IP or hostname must fail immediately without DNS or a connection attempt.
