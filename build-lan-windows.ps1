param([switch]$SkipBridge)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw 'Run this script in PowerShell 7 on x86_64 Windows.'
}
if (-not $env:VCPKG_ROOT) { throw 'Set VCPKG_ROOT to the prepared codec installation.' }
Push-Location $PSScriptRoot
try {
    $env:RUST_LOG = 'info'
    $env:CARGO_TARGET_DIR = Join-Path $PSScriptRoot 'target'
    Push-Location flutter
    try {
        flutter pub get
        if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency resolution failed.' }
    } finally { Pop-Location }
    if (-not $SkipBridge) {
        flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart --c-output ./flutter/macos/Runner/bridge_generated.h
        if ($LASTEXITCODE -ne 0) { throw 'Bridge generation failed.' }
    }
    cargo build --locked --release -p dylib_virtual_display
    if ($LASTEXITCODE -ne 0) { throw 'Virtual display library build failed.' }
    cargo build --locked --release --lib --features flutter
    if ($LASTEXITCODE -ne 0) { throw 'Rust library build failed.' }
    cargo test --locked --release --lib --features flutter lan_ -- --test-threads=1
    if ($LASTEXITCODE -ne 0) { throw 'LAN regression tests failed.' }
    Push-Location flutter
    try {
        flutter test --no-pub test/lan_network_policy_test.dart
        if ($LASTEXITCODE -ne 0) { throw 'Flutter LAN policy tests failed.' }
        flutter build windows --release --no-pub
        if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows build failed.' }
    } finally { Pop-Location }

    $bundle = 'flutter/build/windows/x64/runner/Release'
    Copy-Item target/release/deps/dylib_virtual_display.dll $bundle
    foreach ($file in 'rustdesk.exe', 'librustdesk.dll', 'flutter_windows.dll', 'data/icudtl.dat', 'data/app.so') {
        if (-not (Test-Path "$bundle/$file")) { throw "Incomplete bundle: $file" }
    }
    $version = (Select-String '^version = "([^"]+)"' Cargo.toml | Select-Object -First 1).Matches[0].Groups[1].Value
    $name = "rustdesk-lan-$version-windows-x86_64"
    $releaseDir = Join-Path $PSScriptRoot 'build/releases/windows'
    $package = Join-Path $releaseDir $name
    if (Test-Path $package) { Remove-Item -Recurse -Force $package }
    New-Item -ItemType Directory -Force $package | Out-Null
    Copy-Item "$bundle/*" $package -Recurse
    Get-ChildItem $package -Filter '*.pdb' -Recurse | Remove-Item
    Copy-Item LICENCE $package
    $commit = git rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify source commit.' }
    @{
        version = $version
        source_commit = $commit
        architecture = 'x86_64'
        flutter_version = '3.24.5'
        rust_features = 'flutter'
        signed = $false
    } | ConvertTo-Json | Set-Content "$package/BUILD-INFO.json" -Encoding utf8
    @"
RustDesk LAN $version - Windows x86_64

Extract the entire ZIP into a folder and run rustdesk.exe. Keep the DLLs and
data directory beside it. Connect using the other computer's private IP address.
Default ports: TCP 21118, UDP 21119 for optional LAN discovery.

This build is unsigned and uses software video codecs. It does not bundle the
optional virtual-display or printer drivers or the topmost-window privacy helper.
LAN IP display and discovery use local Windows adapter data without public probes.
Windows discovery replies do not include a MAC address for wake-on-LAN.

Built from https://github.com/dryaf/rustdesk/tree/$commit
See LICENCE and data/flutter_assets/NOTICES.Z for license notices.
An interactive remote desktop session still needs testing on a real Windows PC.
"@ | Set-Content "$package/README.txt" -Encoding utf8
    $archive = Join-Path $releaseDir "$name.zip"
    Compress-Archive -Path $package -DestinationPath $archive -Force
    $hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $name.zip" | Set-Content "$archive.sha256" -Encoding ascii
    Write-Host "Built: $archive"
} finally { Pop-Location }
