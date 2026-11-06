#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
build_args=(-c release)
if [[ -n "${REIMBUR_BUILD_ARCH:-}" ]]; then
    build_args+=(--arch "$REIMBUR_BUILD_ARCH")
fi
swift build "${build_args[@]}"
binary_dir=$(swift build "${build_args[@]}" --show-bin-path)
app_dir="$PWD/dist/Reimbur.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/Reimbur" "$app_dir/Contents/MacOS/Reimbur"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
swift scripts/make-icon.swift "$app_dir/Contents/Resources"
codesign --force --sign - "$app_dir"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")
architecture="${REIMBUR_BUILD_ARCH:-$(uname -m)}"
dmg_path="$PWD/dist/Reimbur-v${version}-macOS-${architecture}.dmg"
dmg_staging=$(mktemp -d "${TMPDIR:-/tmp}/Reimbur-dmg.XXXXXX")
trap 'rm -rf "$dmg_staging"' EXIT
cp -R "$app_dir" "$dmg_staging/Reimbur.app"
ln -s /Applications "$dmg_staging/Applications"
hdiutil create -quiet -volname "Reimbur ${version}" -srcfolder "$dmg_staging" -ov -format UDZO "$dmg_path"
print "已生成：$app_dir"
print "已生成：$dmg_path"
