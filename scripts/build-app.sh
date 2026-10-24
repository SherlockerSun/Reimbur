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
print "已生成：$app_dir"
