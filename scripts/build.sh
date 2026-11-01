#!/bin/zsh
# Compile-check for the simulator; prints only errors and the result line.
cd "${0:A:h}/.."
xcodegen generate >/dev/null 2>&1
xcodebuild -project OrivioTV.xcodeproj -scheme OrivioTV -destination 'generic/platform=tvOS Simulator' \
  -derivedDataPath build/DD build 2>&1 | grep -E "^/.*(error|warning: unre).*|BUILD (SUCCEEDED|FAILED)" | grep -v "/Vendor/\|SourcePackages" | sort -u | head -${1:-80}
