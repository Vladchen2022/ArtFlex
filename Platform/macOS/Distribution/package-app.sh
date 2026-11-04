#!/bin/bash
set -euo pipefail

# Package build products bound to a verified source/build manifest.
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 BUILD_PRODUCTS_DIRECTORY OUTPUT.app" >&2
    exit 1
fi

distribution_dir="$(cd "$(dirname "$0")" && pwd)"
products_dir="$1"
output_app="$2"
icon_source="$distribution_dir/../Resources/AppIcon.png"

if [[ "$output_app" != *.app || -e "$output_app" || -L "$output_app" ]]; then
    echo "Output must be a new .app path: $output_app" >&2
    exit 1
fi
if [[ ! -x "$products_dir/ArtFlex" || ! -d "$products_dir/ArtFlex_ArtFlex.bundle" ]]; then
    echo "Missing ArtFlex executable or resource bundle in: $products_dir" >&2
    exit 1
fi

python3 "$distribution_dir/release.py" verify-products "$products_dir" >/dev/null

scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/artflex-package.XXXXXX")"
trap 'rm -rf "$scratch_dir"' EXIT
iconset_dir="$scratch_dir/AppIcon.iconset"
mkdir -p "$iconset_dir"

# Apple iconutil consumes the standard 1x/2x iconset sizes. Keep the existing
# 1024px artwork as the single source for both runtime and installed icons.
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_source" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$icon_source" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_dir" -o "$scratch_dir/AppIcon.icns"

staged_app="$scratch_dir/ArtFlex.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$distribution_dir/Info.plist" "$staged_app/Contents/Info.plist"
cp "$products_dir/ArtFlex" "$staged_app/Contents/MacOS/ArtFlex"
ditto "$products_dir/ArtFlex_ArtFlex.bundle" "$staged_app/Contents/Resources/ArtFlex_ArtFlex.bundle"
cp "$products_dir/BuildManifest.json" "$staged_app/Contents/Resources/BuildManifest.json"
cp "$scratch_dir/AppIcon.icns" "$staged_app/Contents/Resources/AppIcon.icns"
plutil -lint "$staged_app/Contents/Info.plist"
codesign --force --deep --sign - "$staged_app"
codesign --verify --deep --strict "$staged_app"

mkdir -p "$(dirname "$output_app")"
ditto "$staged_app" "$output_app"
python3 "$distribution_dir/release.py" verify-app "$output_app" >/dev/null
echo "Packaged: $output_app"
