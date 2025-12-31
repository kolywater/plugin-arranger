#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

# Quit existing instances
pkill -x PluginArranger 2>/dev/null || true

xcodebuild -project PluginArranger.xcodeproj \
  -scheme PluginArranger \
  -configuration Debug \
  -derivedDataPath build \
  -quiet

open build/Build/Products/Debug/PluginArranger.app
