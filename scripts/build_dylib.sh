#!/bin/bash
set -euo pipefail
mkdir -p build/inject dist
sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$sdk_path" \
  -miphoneos-version-min=18.0 -fobjc-arc -fmodules \
  -c Inject/Bootstrap.m -o build/inject/Bootstrap.o
xcrun --sdk iphoneos clang++ -arch arm64 -isysroot "$sdk_path" \
  -O2 -DNDEBUG -miphoneos-version-min=18.0 -std=c++17 -fobjc-arc -fmodules \
  -c Inject/PlayerSnapshot.mm -o build/inject/PlayerSnapshot.o
xcrun --sdk iphoneos swiftc -swift-version 5 -O -emit-library \
  -module-name BRMenuInject -import-objc-header Inject/PlayerSnapshot.h -target arm64-apple-ios18.0 -sdk "$sdk_path" \
  Sources/DiagnosticMenu/DiagnosticMenu.swift Inject/BRMenuEntry.swift \
  build/inject/Bootstrap.o build/inject/PlayerSnapshot.o -lc++ -framework UIKit -framework Foundation -framework GLKit -framework QuartzCore \
  -Xlinker -u -Xlinker _BRMenuQueueHook15 -Xlinker -u -Xlinker _BRMenuAspectHook17 \
  -Xlinker -install_name -Xlinker '@rpath/BRMenuInject.dylib' \
  -o dist/BRMenuInject.dylib
xcrun lipo dist/BRMenuInject.dylib -verify_arch arm64
file dist/BRMenuInject.dylib
xcrun otool -L dist/BRMenuInject.dylib > dist/dylib-dependencies.txt
xcrun otool -l dist/BRMenuInject.dylib > dist/dylib-load-commands.txt
python3 scripts/check_dylib.py dist/BRMenuInject.dylib
shasum -a 256 dist/BRMenuInject.dylib > dist/BRMenuInject-SHA256.txt

xcrun nm -gU dist/BRMenuInject.dylib > dist/dylib-exports.txt
python3 -c "from pathlib import Path; assert '_BRMenuQueueHook15' in Path('dist/dylib-exports.txt').read_text(), 'shot hook export missing'"

python3 -c "from pathlib import Path; assert '_BRMenuAspectHook17' in Path('dist/dylib-exports.txt').read_text(), 'aspect hook export missing'"
