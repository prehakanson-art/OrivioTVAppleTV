#!/bin/zsh
# Builds the two sideloadable IPAs from one Release build (§14).
#
#   …Sideload.ipa    ids as built (com.orivio.tv.appletv.dev + .topshelf):
#                    installs alongside an existing Orivio, with its own data.
#   …Sideloadly.ipa  ids rewritten to com.orivio.tv.appletv (app AND every
#                    appex), so an existing sideloaded install updates in place.
#
# Sideloadly / AltStore re-sign the bundle with the user's Apple ID, so no
# distribution signature is needed here.
set -euo pipefail
cd "${0:A:h}/.."

DIST_ID="com.orivio.tv.appletv"
OUT_DIR="ipa_out"
# Info.plist holds $(MARKETING_VERSION); project.yml is the real source.
VERSION=$(grep -m1 'MARKETING_VERSION:' project.yml | sed 's/.*: *"\(.*\)"/\1/' || true)
[ -n "$VERSION" ] || VERSION="0.0.0"

xcodegen generate >/dev/null

# Ask xcodebuild where this configuration's product goes (never guess a DerivedData
# dir), and delete the old one first: whatever gets packaged is guaranteed fresh.
BUILT=$(xcodebuild -project OrivioTV.xcodeproj -scheme OrivioTV -destination 'generic/platform=tvOS' \
  -configuration Release -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')
APP="$BUILT/OrivioTV.app"
[ -n "$BUILT" ] && rm -rf "$APP"

echo "==> Building Release $VERSION…"
# Keep xcodebuild's own status: piping into grep would mask a failed build.
set +e
# UNSIGNED=1 skips code signing (Sideloadly / AltStore re-sign anyway) — for
# when a free account can't provision an id, e.g. the Top Shelf extension.
SIGN_ARGS=(-allowProvisioningUpdates)
[ "${UNSIGNED:-0}" = 1 ] && SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
xcodebuild -project OrivioTV.xcodeproj -scheme OrivioTV -destination 'generic/platform=tvOS' \
  -configuration Release "${SIGN_ARGS[@]}" build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
BUILD_STATUS="${pipestatus[1]}"
set -e
[ "$BUILD_STATUS" -eq 0 ] || { echo "!! Release build failed (status $BUILD_STATUS)"; exit 1; }
[ -d "$APP" ] || { echo "!! Release .app not found at $APP"; exit 1; }

mkdir -p "$OUT_DIR"

# $1 = filename suffix, $2 = app id ("" keeps the built ids)
package() {
  local suffix="$1" appid="${2:-}" work ipa check
  work=$(mktemp -d)
  mkdir -p "$work/Payload"
  cp -R "$APP" "$work/Payload/"
  if [ -n "$appid" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $appid" "$work/Payload/OrivioTV.app/Info.plist"
    # An appex id must be prefixed by its host's, so every extension follows the app.
    for plist in "$work/Payload/OrivioTV.app/PlugIns"/*.appex/Info.plist(N); do
      local old=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist")
      /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $appid.${old##*.}" "$plist"
    done
  fi
  ipa="$OUT_DIR/OrivioTV-V$VERSION.$suffix.ipa"
  rm -f "$ipa"
  (cd "$work" && zip -qry "$OLDPWD/$ipa" Payload)
  rm -rf "$work"

  # Read the ids back out of the zip: they are the whole difference between the two files.
  check=$(mktemp -d)
  unzip -qo "$ipa" 'Payload/OrivioTV.app/Info.plist' 'Payload/OrivioTV.app/PlugIns/*/Info.plist' -d "$check"
  echo "==> $(du -h "$ipa" | cut -f1)  $ipa"
  echo "    app:     $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$check/Payload/OrivioTV.app/Info.plist")"
  for plist in "$check/Payload/OrivioTV.app/PlugIns"/*.appex/Info.plist(N); do
    echo "    plugin:  $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
  done
  rm -rf "$check"
}

package "Sideload" ""
package "Sideloadly" "$DIST_ID"

echo
echo "Sideload.ipa   — installs alongside an existing Orivio (its own data)."
echo "Sideloadly.ipa — updates an existing sideloaded Orivio in place."
