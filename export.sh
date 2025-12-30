#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

echo "Archiving PluginArranger..."
xcodebuild archive \
  -project PluginArranger.xcodeproj \
  -scheme PluginArranger \
  -archivePath build/PluginArranger.xcarchive \
  -quiet

echo "Exporting app..."
xcodebuild -exportArchive \
  -archivePath build/PluginArranger.xcarchive \
  -exportPath Export \
  -exportOptionsPlist ExportOptions.plist

echo "Done! App exported to: $PROJECT_DIR/Export/PluginArranger.app"
