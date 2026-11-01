#!/usr/bin/env bash
# Wrapper that runs the Ruby Xcode patcher, installing xcodeproj if needed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! command -v ruby >/dev/null 2>&1; then
  echo "错误：未找到 ruby（macOS runner 应自带）。" >&2
  exit 1
fi

if ! ruby -e "require 'xcodeproj'" 2>/dev/null; then
  echo "==> 安装 xcodeproj gem ..."
  gem install xcodeproj --no-document || sudo gem install xcodeproj --no-document
fi

exec ruby scripts/patch_ios.rb
