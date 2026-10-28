#!/bin/bash
set -euo pipefail
mkdir -p build/inject dist
license_flags=(-D BRMENU_UNLICENSED)
license_sources=(Inject/LicenseGate.swift)
if [[ "${BRMENU_LICENSED:-0}" == "1" ]]; then
  python3 scripts/license_config.py build/inject/LicenseConfiguration.swift
  license_flags=(-D BRMENU_LICENSED)
  license_sources+=(build/inject/LicenseConfiguration.swift)
fi
sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$sdk_path" \
  -miphoneos-version-min=18.0 -fobjc-arc -fmodules \
  -c Inject/Bootstrap.m -o build/inject/Bootstrap.o
xcrun --sdk iphoneos clang++ -arch arm64 -isysroot "$sdk_path" \
  -O2 -DNDEBUG -miphoneos-version-min=18.0 -std=c++17 -fobjc-arc -fmodules \
  -c Inject/PlayerSnapshot.mm -o build/inject/PlayerSnapshot.o
xcrun --sdk iphoneos swiftc -swift-version 5 -O -emit-library \
  -module-name BRMenuInject -import-objc-header Inject/PlayerSnapshot.h -target arm64-apple-ios18.0 -sdk "$sdk_path" \
  Sources/DiagnosticMenu/DiagnosticMenu.swift Sources/DiagnosticMenu/ReactEvent25.swift Sources/DiagnosticMenu/ReactSound25.swift Sources/DiagnosticMenu/ReactPerformance25.swift Sources/DiagnosticMenu/ReactCommands.swift Sources/DiagnosticMenu/ReactHostUI.swift Inject/BRMenuEntry.swift "${license_sources[@]}" "${license_flags[@]}" \
  build/inject/Bootstrap.o build/inject/PlayerSnapshot.o -lc++ -framework UIKit -framework Foundation -framework OpenGLES -framework MetalKit -framework GLKit -framework QuartzCore -framework Security -framework AVFoundation -framework UniformTypeIdentifiers \
  -Xlinker -u -Xlinker _BRMenuQueueHook15 -Xlinker -u -Xlinker _BRMenuAspectHook17 \
  -Xlinker -u -Xlinker _BRMenuFOV19 -Xlinker -u -Xlinker _BRMenuClock19 -Xlinker -u -Xlinker _BRMenuWeather19 -Xlinker -u -Xlinker _BRMenuChat19 \
  -Xlinker -u -Xlinker _BRMenuLag20 -Xlinker -u -Xlinker _BRMenuFireHeld20 -Xlinker -u -Xlinker _BRMenuFirePressed20 -Xlinker -u -Xlinker _BRMenuStun20 -Xlinker -u -Xlinker _BRMenuFreeze20 \
  -Xlinker -u -Xlinker _BRMenuIncoming25 -Xlinker -u -Xlinker _BRMenuWater24 -Xlinker -u -Xlinker _BRMenuTrace21 -Xlinker -u -Xlinker _BRMenuSound21 -Xlinker -u -Xlinker _BRMenuImpact21 -Xlinker -u -Xlinker _BRMenuLogo21 -Xlinker -u -Xlinker _BRMenuChat21 \
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


python3 -c "from pathlib import Path; e=Path('dist/dylib-exports.txt').read_text(); assert all(x in e for x in ['_BRMenuFOV19','_BRMenuClock19','_BRMenuWeather19','_BRMenuChat19'])"

python3 -c "from pathlib import Path; e=Path('dist/dylib-exports.txt').read_text(); assert all(x in e for x in ['_BRMenuLag20','_BRMenuFireHeld20','_BRMenuFirePressed20','_BRMenuStun20','_BRMenuFreeze20'])"

python3 -c "from pathlib import Path; e=Path('dist/dylib-exports.txt').read_text(); assert all('_'+x in e for x in ['BRMenuTrace21','BRMenuSound21','BRMenuImpact21','BRMenuLogo21','BRMenuChat21'])"

