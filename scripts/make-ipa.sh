#!/bin/zsh
# Build the two sideloadable IPAs of Orivio TV.
#
# The PROJECT signs everything as com.orivio.tv.appletv.dev (the id this
# machine's Personal Team owns) so local Xcode archives and device runs work.
# This script produces the DISTRIBUTION artifacts from that one Release build.
# No distribution signature is needed — Sideloadly/AltStore re-sign the whole
# bundle with each sideloader's own Apple ID (and uniquify the id when Apple's
# registry demands it).
#
# TWO VARIANTS, differing ONLY in bundle identifier:
#
#   …Sideload.ipa     ids left exactly as built — com.orivio.tv.appletv.dev
#                     and …dev.topshelf. Installs ALONGSIDE a previously
#                     sideloaded Orivio: separate icon, separate local data.
#
#   …Sideloadly.ipa   ids swapped back to the historical com.orivio.tv.appletv
#                     and …topshelf, so an existing sideloaded install UPDATES
#                     IN PLACE and keeps its library, progress and add-ons.
#
# Verified against the shipped V7 pair: those two artifacts differ in exactly
# two files (the app's Info.plist and the Top Shelf appex's), and in exactly
# one string each — the identifier.
set -euo pipefail
cd "$(dirname "$0")/.."

DIST_ID="com.orivio.tv.appletv"
# Config/Info.plist holds $(MARKETING_VERSION), so PlistBuddy would return the
# literal variable (or a stale 1.0). project.yml is the real source.
# `|| true` is required: with `set -o pipefail`, a grep that finds nothing makes
# the pipeline non-zero, and `set -e` would abort the assignment before the
# fallback below could run.
VERSION=$(grep -m1 'MARKETING_VERSION:' project.yml 2>/dev/null | sed 's/.*: *"\(.*\)"/\1/' || true)
[ -n "$VERSION" ] || VERSION="0.0.0"
OUT_DIR="ipa_out"

echo "==> Building Release…"
# Capture xcodebuild's OWN exit status. Piping into grep masks it (the pipeline
# returns grep's status, which is 1 whenever the build printed no matching
# line), so `set -e` could not catch a failed build.
set +e
xcodebuild -project OrivioTV.xcodeproj -scheme OrivioTV \
  -destination 'generic/platform=tvOS' -configuration Release \
  -allowProvisioningUpdates build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
BUILD_STATUS="${pipestatus[1]}"
set -e
[ "$BUILD_STATUS" -eq 0 ] || { echo "!! xcodebuild build failed (status $BUILD_STATUS)"; exit 1; }

# `ls DerivedData/OrivioTV-*/… | head -1` used to pick an ARBITRARY (often
# months-stale) derived-data dir, so a failed build still packaged an old .app.
# Ask xcodebuild where it actually put this configuration's product.
BUILT=$(xcodebuild -project OrivioTV.xcodeproj -scheme OrivioTV \
  -destination 'generic/platform=tvOS' -configuration Release \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')
APP="$BUILT/OrivioTV.app"
[ -d "$APP" ] || { echo "!! Release .app not found at $APP"; exit 1; }
# The old mtime heuristic here ("refuse if the .app is over 10 minutes old")
# also rejected a valid incremental build that had nothing to relink. The
# xcodebuild exit status above is the real success signal, so trust it.

mkdir -p "$OUT_DIR"

# $1 = suffix for the filename, $2 = app id ("" leaves it as built)
package() {
  local suffix="$1" appid="${2:-}"
  local work
  work=$(mktemp -d)
  mkdir -p "$work/Payload"
  cp -R "$APP" "$work/Payload/"

  if [ -n "$appid" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $appid" \
      "$work/Payload/OrivioTV.app/Info.plist"
    # THE EXTENSION'S ID MUST FOLLOW THE APP'S. An .appex identifier has to be
    # prefixed by its host app's, or the bundle is malformed and installation
    # fails — so moving the app id without moving the Top Shelf's would ship a
    # broken IPA. Every plugin is rewritten by taking its LAST component, which
    # keeps this correct if a second extension is ever added.
    for plist in "$work/Payload/OrivioTV.app/PlugIns"/*.appex/Info.plist(N); do
      local old leaf
      old=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist")
      leaf="${old##*.}"
      /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $appid.$leaf" "$plist"
    done
  fi

  local ipa="$OUT_DIR/OrivioTV-V$VERSION.$suffix.ipa"
  rm -f "$ipa"
  (cd "$work" && zip -qry "$OLDPWD/$ipa" Payload)
  rm -rf "$work"

  # Read the ids back OUT OF THE ZIP rather than trusting the edit: the whole
  # difference between these two artifacts is those strings, and a silent
  # PlistBuddy no-op would produce two identical IPAs that look right.
  local check
  check=$(mktemp -d)
  unzip -qo "$ipa" 'Payload/OrivioTV.app/Info.plist' \
                   'Payload/OrivioTV.app/PlugIns/*/Info.plist' -d "$check"
  echo "==> $(du -h "$ipa" | cut -f1)  $ipa"
  echo "    app:      $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
                          "$check/Payload/OrivioTV.app/Info.plist")"
  for plist in "$check/Payload/OrivioTV.app/PlugIns"/*.appex/Info.plist(N); do
    echo "    plugin:   $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
  done
  rm -rf "$check"
}

echo "==> Packaging from $APP"
package "Sideload"   ""
package "Sideloadly" "$DIST_ID"

echo
echo "Sideload.ipa   — installs alongside an existing Orivio (its own data)."
echo "Sideloadly.ipa — updates an existing sideloaded Orivio in place."
echo "Both are re-signed by Sideloadly / AltStore with your own Apple ID."
