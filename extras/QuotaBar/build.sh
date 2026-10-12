#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p .build/swift-module-cache QuotaBar.app/Contents/MacOS
quota_module_cache=$(cd .build/swift-module-cache && pwd -P)
xcrun swiftc QuotaBar.swift -module-cache-path "$quota_module_cache" -framework AppKit -o QuotaBar.app/Contents/MacOS/QuotaBar
QuotaBar.app/Contents/MacOS/QuotaBar --self-test
codesign --force --sign - QuotaBar.app
