#!/usr/bin/env bash
# Fetches the pinned third-party sources that native/ compiles into
# libterra_core, verifies their SHA-256, extracts them into third_party/,
# and applies patches. Safe to re-run: up-to-date components are skipped.
#
#   tooling/fetch_third_party.sh          # fetch / verify everything
#   tooling/fetch_third_party.sh --force  # re-extract even if up to date
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TP="$ROOT/third_party"
DL="$TP/.downloads"
PATCHES="$ROOT/tooling/patches"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

# name|url|sha256|archive file name
# Order matters: faad2 is patched with a file shipped inside nrsc5.
DEPS=(
  "nrsc5|https://github.com/theori-io/nrsc5/archive/refs/tags/v3.2.0.tar.gz|8e3bc5ca66256da7c16b617cbd0271a62096411c08e973893191b83c02ecae21|nrsc5-3.2.0.tar.gz"
  "faad2|https://github.com/knik0/faad2/archive/refs/tags/2.11.2.tar.gz|3fcbd305e4abd34768c62050e18ca0986f7d9c5eca343fb98275418013065c0e|faad2-2.11.2.tar.gz"
  "libusb|https://github.com/libusb/libusb/archive/refs/tags/v1.0.30.tar.gz|2ae28adb0bb9558c86135c4e1c11b320b0805461e207a64a6e520a114094bf07|libusb-1.0.30.tar.gz"
  "rtl-sdr|https://github.com/AlexandreRouma/rtl-sdr/archive/ddd6811b71359c299cf31b4e3e75fbb1ed5c964d.tar.gz|dc6e8b1a3125c927df407dfdb435be709fbf4d4d2e8b27c8b50a4134c034fa2e|rtl-sdr-ddd6811b.tar.gz"
  "miniaudio|https://github.com/mackron/miniaudio/archive/refs/tags/0.11.25.tar.gz|b900edcffe979816e2560a0580b9b1216d674b4f17fbadeca8f777a7f8ab0274|miniaudio-0.11.25.tar.gz"
)

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

apply_patches() {
  local name="$1" dir="$2"
  case "$name" in
    faad2)
      patch -p1 -N -s -d "$dir" < "$TP/nrsc5/support/faad2-hdc-support.patch"
      ;;
  esac
  if [[ -d "$PATCHES/$name" ]]; then
    local p
    for p in "$PATCHES/$name"/*.patch; do
      [[ -e "$p" ]] || continue
      patch -p1 -N -s -d "$dir" < "$p"
    done
  fi
}

patch_fingerprint() {
  local name="$1"
  if [[ -d "$PATCHES/$name" ]]; then
    cat "$PATCHES/$name"/*.patch 2>/dev/null | (command -v sha256sum >/dev/null && sha256sum || shasum -a 256) | cut -d' ' -f1
  else
    echo none
  fi
}

mkdir -p "$DL"
for entry in "${DEPS[@]}"; do
  IFS='|' read -r name url want file <<<"$entry"
  dest="$TP/$name"
  stamp_value="$want $(patch_fingerprint "$name")"

  if [[ $FORCE -eq 0 && -f "$dest/.terra-stamp" && "$(cat "$dest/.terra-stamp")" == "$stamp_value" ]]; then
    echo "✓ $name (up to date)"
    continue
  fi

  archive="$DL/$file"
  if [[ ! -f "$archive" || "$(sha256 "$archive")" != "$want" ]]; then
    echo "↓ $name"
    curl -fsSL --retry 3 -o "$archive.part" "$url"
    mv "$archive.part" "$archive"
  fi
  got="$(sha256 "$archive")"
  if [[ "$got" != "$want" ]]; then
    echo "✗ $name: SHA-256 mismatch (expected $want, got $got)" >&2
    exit 1
  fi

  rm -rf "$dest" "$dest.tmp"
  mkdir -p "$dest.tmp"
  tar -xzf "$archive" -C "$dest.tmp" --strip-components=1
  apply_patches "$name" "$dest.tmp"
  echo "$stamp_value" > "$dest.tmp/.terra-stamp"
  mv "$dest.tmp" "$dest"
  echo "✓ $name"
done
