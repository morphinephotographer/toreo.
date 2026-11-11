#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
destination="${1:?Pass the Resources directory}"
composer="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
mkdir -p "$destination"

render() {
    local name="$1" appearance="$2"
    shift 2
    "$composer" "$root/Icon/AppIcon.icon" --export-image \
        --output-file "$destination/Dock-$name.png" \
        --platform macOS --rendition "$appearance" --width 512 --height 512 --scale 1 "$@"
}

render waves Default
render dark Dark
render clearLight ClearLight
render clearDark ClearDark
render blue TintedLight --tint-color 0.61 --tint-strength 0.8
render green TintedLight --tint-color 0.50 --tint-strength 0.8
