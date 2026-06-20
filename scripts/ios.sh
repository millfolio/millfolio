#!/usr/bin/env bash
# Regenerate + build the Millfolio iOS app. With `run`, also install + launch on
# the simulator and grab a screenshot to /tmp/mf-ios.png.
#   scripts/ios.sh        # build only
#   scripts/ios.sh run    # build + launch on iPhone 17 sim
set -uo pipefail
IOS="/Users/mseritan/dev/millfolio/app/ios"
DEST='platform=iOS Simulator,name=iPhone 17,OS=26.5'
BUNDLE="com.millfolio.app"

cd "$IOS" || exit 1
command -v xcodegen >/dev/null || { echo "xcodegen not installed (brew install xcodegen)"; exit 1; }
xcodegen generate >/dev/null

if xcodebuild -project Millfolio.xcodeproj -scheme Millfolio -sdk iphonesimulator \
     -destination "$DEST" -configuration Debug build CODE_SIGNING_ALLOWED=NO \
     >/tmp/mf-ios-build.log 2>&1; then
  echo "✅ iOS build OK"
else
  echo "❌ iOS BUILD FAILED  → /tmp/mf-ios-build.log"
  grep -E 'error:|BUILD FAILED' /tmp/mf-ios-build.log | head
  exit 1
fi

[ "${1:-}" = "run" ] || exit 0

DEV=$(xcrun simctl list devices available | sed -n 's/.*iPhone 17 (\([0-9A-F-]*\)).*/\1/p' | head -1)
APP=$(find ~/Library/Developer/Xcode/DerivedData/Millfolio-*/Build/Products/Debug-iphonesimulator \
       -name 'Millfolio.app' 2>/dev/null | head -1)
[ -n "$DEV" ] && [ -n "$APP" ] || { echo "could not locate sim device / built app"; exit 1; }
xcrun simctl boot "$DEV" 2>/dev/null; sleep 2
xcrun simctl install "$DEV" "$APP" && xcrun simctl launch "$DEV" "$BUNDLE" && echo "launched $BUNDLE"
sleep 3
xcrun simctl io "$DEV" screenshot /tmp/mf-ios.png >/dev/null 2>&1 && echo "screenshot → /tmp/mf-ios.png"
