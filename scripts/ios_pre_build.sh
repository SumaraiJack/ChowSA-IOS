#!/usr/bin/env bash
# Run before `flutter build ios` on the Mac build machine.
# Fixes the google_mobile_ads (CocoaPods) vs webview_flutter_wkwebview (SPM)
# resolver conflict by disabling Swift Package Manager for this build.
set -euo pipefail

flutter config --no-enable-swift-package-manager
rm -rf ios/Pods ios/Podfile.lock ios/.symlinks ios/Runner.xcworkspace/xcshareddata/swiftpm
flutter clean
flutter pub get
