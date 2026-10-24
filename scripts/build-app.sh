#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
swift build -c release
binary_dir=$(swift build -c release --show-bin-path)
app_dir="$PWD/dist/Reimbur.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/Reimbur" "$app_dir/Contents/MacOS/Reimbur"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
swift scripts/make-icon.swift "$app_dir/Contents/Resources"
codesign --force --sign - "$app_dir"
print "已生成：$app_dir"
