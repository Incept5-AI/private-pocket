#!/bin/zsh
# Build unsigned, sign with an existing development profile and certificate, install
# and launch on a phone. For when Xcode has no Apple ID signed in, so automatic
# signing cannot run. Settings come from signing.env (see signing.env.example);
# DEVICE=… on the command line overrides it. With an Apple ID in Xcode you can
# instead open the generated project and run it from Xcode.
set -euo pipefail
cd "${0:A:h}"
cli_device=${DEVICE:-}
[[ -f signing.env ]] || { echo "copy signing.env.example to signing.env and fill it in"; exit 1; }
source ./signing.env
DEVICE=${cli_device:-$DEVICE}
for v in DEVICE PROFILE IDENTITY APP_ID_PREFIX TEAM_ID; do [[ -n ${(P)v} ]] || { echo "$v is not set in signing.env"; exit 1; }; done
APP=build/Build/Products/Debug-iphoneos/PrivatePocket.app

./gen-defaults.sh          # before xcodegen, so Generated/ exists and gets into the project
xcodegen generate -q
xcodebuild -project PrivatePocket.xcodeproj -scheme PrivatePocket -destination 'generic/platform=iOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build -quiet

for d in ~/Library/MobileDevice/Provisioning\ Profiles ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles; do
  [[ -f "$d/$PROFILE.mobileprovision" ]] && cp "$d/$PROFILE.mobileprovision" "$APP/embedded.mobileprovision"
done
[[ -f "$APP/embedded.mobileprovision" ]] || { echo "profile $PROFILE not found"; exit 1; }

PREFIX=$APP_ID_PREFIX
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")

# Entitlements for a bundle id, as Xcode writes them for a development build. A second
# bundle id adds that bundle's Keychain group (the extension reads the app's SharedState).
entitlements() {
  local f=$(mktemp -t ent).plist
  cat > "$f" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>$PREFIX.$1</string>
  <key>com.apple.developer.team-identifier</key><string>$TEAM_ID</string>
  <key>get-task-allow</key><true/>
  <key>keychain-access-groups</key><array><string>$PREFIX.$1</string>${2:+<string>$PREFIX.$2</string>}</array>
</dict></plist>
PLIST
  echo "$f"
}

find "$APP" -name '*.dylib' -o -name '*.framework' | while read f; do codesign -f -s $IDENTITY "$f"; done
# App extensions (the Live Activity) get the same profile and their own entitlements,
# and are signed before the app, whose seal covers them.
for x in "$APP"/PlugIns/*.appex(N); do
  cp "$APP/embedded.mobileprovision" "$x/embedded.mobileprovision"
  codesign -f -s $IDENTITY --entitlements "$(entitlements "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$x/Info.plist")" "$BUNDLE")" "$x"
done
codesign -f -s $IDENTITY --entitlements "$(entitlements "$BUNDLE")" "$APP"
codesign -v "$APP"
xcrun devicectl device install app --device $DEVICE "$APP"
xcrun devicectl device process launch --device $DEVICE "$BUNDLE" || true
