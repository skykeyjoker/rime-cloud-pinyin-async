#!/bin/zsh
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../../.." && pwd)
common_dir="$script_dir/../common"
dist_dir="$script_dir/dist"
build_dir="$script_dir/.build"
app_contents=$(printenv FCITX5_APP_CONTENTS || true)
fcitx_source=$(printenv FCITX5_SOURCE || true)
architecture=$(printenv ARCHS || true)

if [[ -z "$app_contents" ]]; then
  app_contents="/Library/Input Methods/Fcitx5.app/Contents"
fi
if [[ -z "$fcitx_source" ]]; then
  fcitx_source="$(dirname "$repo_root")/fcitx5-macos-source/fcitx5"
fi
if [[ -z "$architecture" ]]; then
  architecture=$(uname -m)
fi

if [[ ! -f "$fcitx_source/src/lib/fcitx/instance.h" ]]; then
  print -u2 "Set FCITX5_SOURCE to the fcitx5 submodule inside an fcitx5-macos checkout."
  exit 2
fi
if [[ ! -d "$app_contents/lib" ]]; then
  print -u2 "Fcitx5.app was not found at: $app_contents"
  exit 2
fi

mkdir -p "$dist_dir" "$build_dir"

sdk_path=$(xcrun --sdk macosx --show-sdk-path)
swiftc \
  -swift-version 5 \
  -O \
  -target "$architecture-apple-macos13.3" \
  -sdk "$sdk_path" \
  "$common_dir/helper/CloudPinyinAsyncHelper.swift" \
  -o "$dist_dir/cloud_pinyin_async_helper"

clang++ \
  -std=c++20 \
  -O2 \
  -fvisibility=hidden \
  -mmacosx-version-min=13.3 \
  -arch "$architecture" \
  -I"$script_dir/fcitx-addon/compat" \
  -I"$fcitx_source/src/lib" \
  -bundle \
  -L"$app_contents/lib" \
  -Wl,-rpath,"$app_contents/lib" \
  -lFcitx5Core \
  -lFcitx5Config \
  -lFcitx5Utils \
  "$script_dir/fcitx-addon/cloudpinyinrefresh.cpp" \
  -o "$dist_dir/libcloudpinyinrefresh.so"

chmod 0755 \
  "$dist_dir/cloud_pinyin_async_helper" \
  "$dist_dir/libcloudpinyinrefresh.so"

file \
  "$dist_dir/cloud_pinyin_async_helper" \
  "$dist_dir/libcloudpinyinrefresh.so"
