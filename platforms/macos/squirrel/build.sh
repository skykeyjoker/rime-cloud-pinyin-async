#!/bin/zsh
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
common_dir="$script_dir/../common"
dist_dir="$script_dir/dist"
architecture=${ARCHS:-$(uname -m)}
squirrel_source=${SQUIRREL_SOURCE:-${1:-}}
code_sign_identity=${CODE_SIGN_IDENTITY:-}

mkdir -p "$dist_dir"

sdk_path=$(xcrun --sdk macosx --show-sdk-path)
swiftc \
  -swift-version 5 \
  -O \
  -target "$architecture-apple-macos13.3" \
  -sdk "$sdk_path" \
  "$common_dir/helper/CloudPinyinAsyncHelper.swift" \
  -o "$dist_dir/cloud_pinyin_async_helper"
chmod 0755 "$dist_dir/cloud_pinyin_async_helper"

if [[ -n "$code_sign_identity" ]]; then
  codesign \
    --force \
    --options runtime \
    --timestamp=none \
    --sign "$code_sign_identity" \
    "$dist_dir/cloud_pinyin_async_helper"
fi

codesign --verify --strict "$dist_dir/cloud_pinyin_async_helper"
file "$dist_dir/cloud_pinyin_async_helper"

if [[ -z "$squirrel_source" ]]; then
  print "Built helper only. Set SQUIRREL_SOURCE to also verify and build the patched Squirrel frontend."
  exit 0
fi

if [[ ! -f "$squirrel_source/Makefile" || \
      ! -f "$squirrel_source/sources/SquirrelApplicationDelegate.swift" ]]; then
  print -u2 "Squirrel source checkout was not found at: $squirrel_source"
  exit 2
fi

patch_file="$script_dir/patches/squirrel-cloud-refresh.patch"
if ! git -C "$squirrel_source" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
  if git -C "$squirrel_source" apply --check "$patch_file" >/dev/null 2>&1; then
    print -u2 "Squirrel patch has not been applied. Run:"
    print -u2 "  $script_dir/apply-squirrel-patch.sh '$squirrel_source'"
  else
    print -u2 "Squirrel source is incompatible with the bundled patch."
  fi
  exit 3
fi

derived_data_path=${SQUIRREL_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/RimeCloudSquirrel}
make \
  -C "$squirrel_source" \
  release \
  ARCHS="$architecture" \
  DERIVED_DATA_PATH="$derived_data_path"

squirrel_app="$derived_data_path/Build/Products/Release/Squirrel.app"
if [[ ! -d "$squirrel_app" ]]; then
  print -u2 "Squirrel build finished without the expected app: $squirrel_app"
  exit 4
fi

if [[ -n "$code_sign_identity" ]]; then
  codesign \
    --deep \
    --force \
    --options runtime \
    --timestamp=none \
    --sign "$code_sign_identity" \
    "$squirrel_app"
fi

codesign --verify --deep --strict "$squirrel_app"
if ! strings "$squirrel_app/Contents/MacOS/Squirrel" | grep -q 'SquirrelCloudPinyinResponseReadyNotification'; then
  print -u2 "Built Squirrel executable does not contain the cloud refresh notification."
  exit 5
fi

print "Built helper: $dist_dir/cloud_pinyin_async_helper"
print "Built Squirrel: $squirrel_app"
