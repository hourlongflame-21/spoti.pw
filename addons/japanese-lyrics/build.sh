#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -target arm64-apple-ios16.1 \
  -isysroot "$SDK" -fobjc-arc -fblocks -dynamiclib -O2 \
  -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations \
  -framework Foundation -framework UIKit -framework Security -framework NaturalLanguage -framework CoreGraphics -framework WebKit -framework QuartzCore \
  -install_name @executable_path/Frameworks/SGJapaneseLyrics.dylib \
  SGJapaneseLyrics.m JPPolicy.m JPResearch.m JPTranslationCache.m JPCoreWork.m JPCorePerformance.m -o build/SGJapaneseLyrics.dylib
codesign --force --sign - build/SGJapaneseLyrics.dylib
codesign --verify --verbose build/SGJapaneseLyrics.dylib
xcrun --sdk iphoneos otool -hv build/SGJapaneseLyrics.dylib
shasum -a 256 build/SGJapaneseLyrics.dylib > build/SHA256.txt
echo "Built: build/SGJapaneseLyrics.dylib (device testing still required)"
