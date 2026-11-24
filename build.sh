#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
work="${RILL_BUILD_DIR:-"$root/.build"}"
source_dir="${TRANSMISSION_SOURCE:-"$work/transmission"}"
cmake="${CMAKE:-cmake}"
destination="${RILL_APP_PATH:-"$root/toreo..app"}"
mkdir -p "$work"
if [[ ! -e "$source_dir/.git" && ! -f "$source_dir/TOREO_SOURCE_REVISION" ]]; then
  git clone --branch 4.1.4 --depth 1 https://github.com/transmission/transmission.git "$source_dir"
fi
if [[ -e "$source_dir/.git" ]]; then
  source_revision="$(git -C "$source_dir" rev-parse HEAD)"
else
  source_revision="$(cat "$source_dir/TOREO_SOURCE_REVISION")"
fi
if [[ "$source_revision" != a6d907d9ea2313143af714d7830feb6c1b60b84c ]]; then
  echo "The build requires Transmission 4.1.4 (a6d907d)." >&2
  exit 1
fi
if [[ -e "$source_dir/.git" ]] && git -C "$source_dir" submodule status --recursive | grep -q '^-'; then
  git -C "$source_dir" submodule update --init --recursive --depth 1
fi
# libpsl embeds the input filename in its generated data. Keep that metadata portable.
psl_generator="$source_dir/third-party/libpsl/src/psl-make-dafsa"
if grep -Fq 'bytes(psl_input_file, **codecs)' "$psl_generator"; then
  patch --silent -d "$source_dir" -p1 < "$root/Engine/patches/libpsl-path.patch"
  rm -f "$work/rill-engine/transmission/third-party/libpsl.bld/src/psl-stamp/"{psl-build,psl-install,psl-done}
fi
"$cmake" -S "$root/Engine" -B "$work/rill-engine" \
  -DTRANSMISSION_SOURCE="$source_dir" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_POLICY_VERSION_MINIMUM=3.5
"$cmake" --build "$work/rill-engine" --target RillEngine -j 8
stage="$(mktemp -d "$work/rill-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/toreo..app"
mkdir -p "$app/Contents/"{MacOS,Frameworks,Resources}
cp "$root/Info.plist" "$app/Contents/Info.plist"
cp "$root/LICENSE" "$root/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/"
cp "$work/rill-engine/libRillEngine.dylib" "$app/Contents/Frameworks/"
cp "$source_dir/COPYING" "$app/Contents/Resources/Transmission-COPYING"
cp -R "$source_dir/licenses" "$app/Contents/Resources/Transmission-licenses"
export CLANG_MODULE_CACHE_PATH="$work/module-cache"
export SWIFT_MODULECACHE_PATH="$work/module-cache"
icon_dir="${TOREO_COMPILED_ICON_DIR:-"$stage/icon"}"
if [[ -z "${TOREO_COMPILED_ICON_DIR:-}" ]]; then
  mkdir -p "$icon_dir"
  xcrun actool "$root/Icon/AppIcon.icon" --compile "$icon_dir" --platform macosx \
    --minimum-deployment-target 26.0 --app-icon AppIcon \
    --output-partial-info-plist "$icon_dir/partial.plist" --output-format human-readable-text --errors --warnings
fi
cp "$icon_dir/Assets.car" "$icon_dir/AppIcon.icns" "$app/Contents/Resources/"
bash "$root/tools/compile-dock-alternate.sh" "$app/Contents/Resources"
macro_flags=()
if [[ "${RILL_DISABLE_MACRO_SANDBOX:-0}" == 1 ]]; then
  macro_flags=(-Xfrontend -disable-sandbox)
fi
# Bash 3.2 treats an empty array as unset under set -u.
xcrun swiftc ${macro_flags[@]+"${macro_flags[@]}"} -swift-version 6 -O -target arm64-apple-macos26.0 \
  -module-cache-path "$work/module-cache" -import-objc-header "$root/Engine/Bridge.h" \
  -L "$app/Contents/Frameworks" -lRillEngine -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "$root"/Sources/*.swift -o "$app/Contents/MacOS/Toreo"
codesign --force --sign - "$app/Contents/Frameworks/libRillEngine.dylib"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
mkdir -p "$(dirname "$destination")"
ditto "$app" "$destination"
printf '%s\n' "$destination"
