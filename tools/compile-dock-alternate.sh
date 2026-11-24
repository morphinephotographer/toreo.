#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
destination="${1:?Pass the Resources directory}"
composer="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
mkdir -p "$destination"

render() {
    local name="$1" appearance="$2"
    shift 2
    "$composer" "$root/Icon/Previous/AppIcon.icon" --export-image \
        --output-file "$destination/Dock-$name.png" \
        --platform macOS --rendition "$appearance" --width 512 --height 512 --scale 1 "$@"
}

render waves Default
render dark Dark
render clearLight ClearLight
render clearDark ClearDark
render blue TintedLight --tint-color 0.61 --tint-strength 0.8
render green TintedLight --tint-color 0.50 --tint-strength 0.8

"$composer" "$root/Icon/Circle/AppIcon.icon" --export-image --output-file "$destination/Dock-status.png" --platform macOS --rendition Default --width 512 --height 512 --scale 1

"$composer" "$root/Icon/AppIcon.icon" --export-image --output-file "$destination/Dock-twoWaves.png" --platform macOS --rendition Default --width 512 --height 512 --scale 1

"$composer" "$root/Icon/ColorVariants/01-blue-mint/AppIcon.icon" --export-image --output-file "$destination/Dock-twoWavesDark.png" --platform macOS --rendition Dark --width 512 --height 512 --scale 1
"$composer" "$root/Icon/ColorVariants/06-monochrome/AppIcon.icon" --export-image --output-file "$destination/Dock-monochromeLight.png" --platform macOS --rendition Default --width 512 --height 512 --scale 1
"$composer" "$root/Icon/ColorVariants/06-monochrome/AppIcon.icon" --export-image --output-file "$destination/Dock-monochromeDark.png" --platform macOS --rendition Dark --width 512 --height 512 --scale 1
