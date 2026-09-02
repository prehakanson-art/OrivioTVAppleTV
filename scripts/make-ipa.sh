#!/bin/zsh
# Build a sideloadable IPA of Orivio TV.
#
# The PROJECT signs everything as com.orivio.tv.appletv.dev (the id this
# machine's Personal Team owns) so local Xcode archives work. This script
# produces the DISTRIBUTION artifact: it builds Release, swaps the bundle
# id back to the historical com.orivio.tv.appletv so existing sideloaders
# update in place with their data, and zips a Payload IPA. No distribution
# signature is needed — Sideloadly/AltStore re-sign the whole bundle with
# each sideloader's own Apple ID (and uniquify the id when Apple's registry
# demands it).
set -euo pipefail
cd "$(dirname "$0")/.."

DIST_ID="com.orivio.tv.appletv"
# Config/Info.plist holds $(MARKETING_VERSION), so PlistBuddy would return the
# literal variable (or a stale 1.0). project.yml is the real source.
VERSION=$(grep -m1 'MARKETING_VERSION:' project.yml | sed 's/.*: *"\(.*\)"/\1/')
[ -n "$VERSION" ] || VERSION="0.0.0"
OUT_DIR="ipa_out"
WORK=$(mktemp -d)

echo "==> Building Release…"
xcodebuild -project OrivioTV.xcodeproj -scheme OrivioTV \
  -destination 'generic/platform=tvOS' -configuration Release \
  -allowProvisioningUpdates build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

# `ls DerivedData/OrivioTV-*/… | head -1` used to pick an ARBITRARY (often
# months-stale) derived-data dir, so a failed build still packaged an old .app.
# Ask xcodebuild where it actually put this configuration's product.
BUILT=$(xcodebuild -project OrivioTV.xcodeproj -scheme OrivioTV \
  -destination 'generic/platform=tvOS' -configuration Release \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')
APP="$BUILT/OrivioTV.app"
[ -d "$APP" ] || { echo "!! Release .app not found at $APP"; exit 1; }

# A build that failed leaves the PREVIOUS .app in place, so freshness is the
# only thing separating a real artifact from a stale one.
if [ -n "$(find "$APP" -maxdepth 0 -mmin +10)" ]; then
  echo "!! $APP is over 10 minutes old — the build did not produce it. Refusing."
  exit 1
fi

echo "==> Packaging from $APP"
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"

# Distribution identity: restore the historical bundle id.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DIST_ID" \
  "$WORK/Payload/OrivioTV.app/Info.plist"

mkdir -p "$OUT_DIR"
IPA="$OUT_DIR/Orivio-TV-$VERSION.ipa"
rm -f "$IPA"
(cd "$WORK" && zip -qry "$OLDPWD/$IPA" Payload)
rm -rf "$WORK"
echo "==> $(du -h "$IPA" | cut -f1)  $IPA"
echo "    Sideload with Sideloadly / AltStore — they re-sign it themselves."
