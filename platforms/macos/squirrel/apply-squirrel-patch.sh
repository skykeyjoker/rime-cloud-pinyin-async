#!/bin/zsh
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
patch_file="$script_dir/patches/squirrel-cloud-refresh.patch"
squirrel_source=${1:-${SQUIRREL_SOURCE:-}}

if [[ -z "$squirrel_source" ]]; then
  print -u2 "Usage: $0 /path/to/squirrel"
  print -u2 "Or set SQUIRREL_SOURCE before running the script."
  exit 2
fi

if [[ ! -f "$squirrel_source/sources/SquirrelApplicationDelegate.swift" || \
      ! -f "$squirrel_source/sources/SquirrelInputController.swift" ]]; then
  print -u2 "Squirrel source checkout was not found at: $squirrel_source"
  exit 2
fi

if git -C "$squirrel_source" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
  print "Squirrel cloud refresh patch is already applied."
  exit 0
fi

if ! git -C "$squirrel_source" apply --check "$patch_file"; then
  print -u2 "The patch does not apply cleanly. Rebase it against the current Squirrel source before building."
  exit 3
fi

git -C "$squirrel_source" apply "$patch_file"
print "Applied Squirrel cloud refresh patch to: $squirrel_source"
