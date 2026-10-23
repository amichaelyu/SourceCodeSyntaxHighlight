#!/bin/zsh
#
# Build Syntax Highlight.app signed with Developer ID, notarize and staple it,
# and leave a distributable zip in build/release/.
#
#   ./release.sh              build, sign, notarize, staple, zip
#   ./release.sh --install    …and then install the stapled app into /Applications
#
# Requirements (one-time):
#   - "Developer ID Application" certificate in the login keychain
#   - notarization credentials stored as a keychain profile:
#       xcrun notarytool store-credentials notary --key AuthKey_XXXX.p8 --key-id XXXX --issuer <uuid>
#
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="Developer ID Application"
TEAM=SNC2X5N2CY
PROFILE=notary
DD=build/DerivedData
APP="$DD/Build/Products/Release/Syntax Highlight.app"
OUT=build/release
VERSION=$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' SourceCodeSyntaxHighlight.xcodeproj/project.pbxproj | head -1)
ZIP="$OUT/Syntax-Highlight-$VERSION-arm64.zip"

echo "==> Building $VERSION"
rm -rf "$DD/Build/Products" "$OUT"
mkdir -p "$OUT"
xcodebuild -project SourceCodeSyntaxHighlight.xcodeproj -scheme SyntaxHighlight -configuration Release \
    -derivedDataPath "$DD" -arch arm64 ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=$TEAM CODE_SIGN_IDENTITY="$IDENTITY" PROVISIONING_PROFILE_SPECIFIER="" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS="--timestamp" \
    build > "$OUT/build.log" 2>&1 || { grep -E "error:" "$OUT/build.log" | sort -u; echo "build failed, see $OUT/build.log"; exit 1; }

echo "==> Re-signing Sparkle helpers"
# The Sparkle package ships its nested helpers ad-hoc signed; notarization needs Developer ID
# throughout. Sign inside out, then re-seal the framework and the app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for b in "$SPARKLE/XPCServices/Downloader.xpc" "$SPARKLE/XPCServices/Installer.xpc" \
         "$SPARKLE/Updater.app" "$SPARKLE/Autoupdate" "$APP/Contents/Frameworks/Sparkle.framework" "$APP"; do
    [ -e "$b" ] || continue
    codesign --force --options runtime --timestamp --preserve-metadata=entitlements -s "$IDENTITY" "$b"
done

echo "==> Verifying signatures"
codesign --verify --deep --strict "$APP"
find "$APP" \( -name "*.app" -o -name "*.appex" -o -name "*.xpc" -o -name "*.framework" -o -name "*.dylib" \) -print0 \
    | while IFS= read -r -d '' b; do
    # grep without -q: with pipefail, an early exit would make codesign fail on SIGPIPE.
    if ! codesign -dvv "$b" 2>&1 | grep "Authority=$IDENTITY" > /dev/null; then
        echo "not Developer ID signed: $b"; exit 1
    fi
    if codesign -d --entitlements - "$b" 2>/dev/null | grep get-task-allow > /dev/null; then
        echo "get-task-allow present: $b"; exit 1
    fi
done

echo "==> Notarizing"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1 | tee "$OUT/notarize.log"
if ! grep -q "status: Accepted" "$OUT/notarize.log"; then
    id=$(grep -m1 "  id:" "$OUT/notarize.log" | awk '{print $2}')
    xcrun notarytool log "$id" --keychain-profile "$PROFILE"
    exit 1
fi

echo "==> Stapling"
xcrun stapler staple "$APP" > /dev/null
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=1 "$APP"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing"
    LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    pkill -f "Syntax Highlight" || true
    rm -rf "/Applications/Syntax Highlight.app"
    ditto "$APP" "/Applications/Syntax Highlight.app"
    $LSR -f -R "/Applications/Syntax Highlight.app"
    pluginkit -a "/Applications/Syntax Highlight.app/Contents/PlugIns/"*.appex
    pluginkit -e use -i com.michaelyu.SourceCodeSyntaxHighlight.QuickLookExtension
    qlmanage -r > /dev/null; qlmanage -r cache > /dev/null
    killall -9 QuickLookUIService 2> /dev/null || true
    killall Finder
fi

echo "==> Done: $ZIP"
