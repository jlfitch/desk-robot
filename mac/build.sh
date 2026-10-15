#!/bin/zsh
# Build the Mac app and install it to ~/Applications. Usage: ./build.sh [--run]
set -e
cd "$(dirname "$0")"
xcodegen generate >/dev/null
rm -rf build/Build/Products/Release/DeskRobot.app
set +e
xcodebuild -project DeskRobot.xcodeproj -scheme DeskRobot -configuration Release \
  -derivedDataPath build build > build/xcodebuild.log 2>&1
rc=$?
set -e
grep -E "error:|BUILD " build/xcodebuild.log | grep -v "^$" | tail -8
APP=build/Build/Products/Release/DeskRobot.app
if [[ $rc -ne 0 || ! -d "$APP" ]]; then echo "build failed (see build/xcodebuild.log)"; exit 1; fi
# Re-sign with a real developer certificate when one is in the keychain, so the
# microphone permission is tied to a stable identity and survives rebuilds.
IDENT=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | awk '{print $2}')
if [[ -n "$IDENT" ]]; then
  codesign --force --deep --sign "$IDENT" "$APP" && echo "signed with Apple Development ($IDENT)"
else
  echo "no Apple Development certificate; leaving the ad-hoc signature"
fi
mkdir -p ~/Applications
rm -rf ~/Applications/DeskRobot.app
cp -R "$APP" ~/Applications/DeskRobot.app
echo "installed ~/Applications/DeskRobot.app"
if [[ "$1" == "--run" ]]; then
  pkill -x DeskRobot 2>/dev/null || true
  sleep 0.5
  open ~/Applications/DeskRobot.app
fi
