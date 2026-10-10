#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"
bundle_args=()
if [[ $# -gt 0 ]]; then bundle_args=(--bundle "$1"); fi
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
unit=$stage/etc/systemd/system/rustdesk.service

./install-lan.sh --destdir "$stage" "${bundle_args[@]}"
grep -qx 'ExecStart=/usr/local/lib/rustdesk-lan/rustdesk --service' "$unit"
grep -qx 'WantedBy=multi-user.target' "$unit"
test -x "$stage/usr/local/lib/rustdesk-lan/rustdesk"
test ! -e "$stage/etc/systemd/system/multi-user.target.wants/rustdesk.service"
printf 'PASS: installs the unit required by Run service without enabling it\n'

./install-lan.sh --destdir "$stage" "${bundle_args[@]}"
grep -qx 'ExecStart=/usr/local/lib/rustdesk-lan/rustdesk --service' "$unit"
printf 'PASS: installer-owned service can be reinstalled\n'

printf '[Unit]\nDescription=Another RustDesk installation\n' > "$unit"
cp "$unit" "$stage/original.service"
if ./install-lan.sh --destdir "$stage" "${bundle_args[@]}"; then
    printf 'FAIL: installer accepted an unrelated service\n' >&2
    exit 1
fi
cmp "$unit" "$stage/original.service"
printf 'PASS: an unrelated service is preserved\n'
