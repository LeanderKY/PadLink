#!/bin/zsh
# Builds both apps into ./dist:  PadLink.app (Mac) and PadLink.apk (Pad).
set -e
cd "${0:A:h}"
mkdir -p dist

echo "▶ Mac-App"
(cd mac && xcodegen generate -q && xcodebuild -project PadLink.xcodeproj -scheme PadLink -configuration Release \
    -derivedDataPath build -quiet build)
rm -rf dist/PadLink.app && cp -R mac/build/Build/Products/Release/PadLink.app dist/
# Sign with a stable certificate so macOS keeps the screen/accessibility permissions across rebuilds
# (ad-hoc signatures change with every build and macOS then silently ignores the old permission).
ID=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')
if [[ -n "$ID" ]]; then codesign --force --deep --timestamp=none -s "$ID" dist/PadLink.app; else echo "⚠ kein Zertifikat – ad-hoc signiert"; fi
(cd dist && rm -f PadLink-Mac.zip && ditto -c -k --keepParent PadLink.app PadLink-Mac.zip)

echo "▶ Pad-App"
(cd android && ./gradlew -q assembleRelease)
cp android/app/build/outputs/apk/release/app-release.apk dist/PadLink.apk

echo "✓ fertig:"; ls -lh dist
