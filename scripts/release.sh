#!/bin/bash
set -euo pipefail

# Usage: ./scripts/release.sh 1.0.0

VERSION="${1:?Usage: ./scripts/release.sh <version>}"
TEAM_ID="W33JZPPPFN"
SIGNING_IDENTITY="Developer ID Application: Sabotage Media, LLC ($TEAM_ID)"
APPLE_ID="josh@sabotagemedia.com"
BUNDLE_ID="com.joshpigford.Chops"

echo "🔨 Building Chops v$VERSION..."

# Generate Xcode project
xcodegen generate

# Clean build
rm -rf build
mkdir -p build

# Archive
xcodebuild -project Chops.xcodeproj \
  -scheme Chops \
  -configuration Release \
  -archivePath build/Chops.xcarchive \
  archive \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION"

# Export
sed "s/\${APPLE_TEAM_ID}/$TEAM_ID/g" ExportOptions.plist > build/ExportOptions.plist
xcodebuild -exportArchive \
  -archivePath build/Chops.xcarchive \
  -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/export

echo "📦 Creating DMG..."
hdiutil create -volname "Chops" \
  -srcfolder build/export/Chops.app \
  -ov -format UDZO \
  build/Chops.dmg

echo "🔏 Notarizing..."
xcrun notarytool submit build/Chops.dmg \
  --keychain-profile "AC_PASSWORD" \
  --wait

echo "📎 Stapling..."
xcrun stapler staple build/export/Chops.app
rm build/Chops.dmg
hdiutil create -volname "Chops" \
  -srcfolder build/export/Chops.app \
  -ov -format UDZO \
  build/Chops.dmg
xcrun stapler staple build/Chops.dmg

echo "🏷️  Tagging v$VERSION..."
git tag "v$VERSION"
git push --tags

echo "🚀 Creating GitHub Release..."
gh release create "v$VERSION" build/Chops.dmg \
  --title "Chops v$VERSION" \
  --generate-notes

echo "✅ Done! Release: https://github.com/Shpigford/chops/releases/tag/v$VERSION"
