# AndroidNav

Android-style virtual navigation bar (Back / Home / Recents) for jailbroken iOS 15+ SpringBoard.

## Cloud Build

Push to `main` or trigger manually via **Actions → Build AndroidNav Tweak → Run workflow**.

The GitHub Actions runner uses a real macOS + Xcode toolchain:
- Apple's `clang` + `ld` (proper Mach-O, no lld hacks needed)
- Apple's `lipo` for fat binary merging
- `ldid` for code signing
- Automatic Mach-O verification (CHAINED_FIXUPS, EXPORTS_TRIE, CODE_SIGNATURE, REEXPORT check)
- Dual-path deb packaging (var/jb + var/mobile for RootHide compatibility)

Download the `.deb` from the Artifacts section after a successful build.

## Local Build (macOS)

```bash
mkdir build
clang -target arm64-apple-ios15.0 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
  -fobjc-arc -shared -framework UIKit -framework Foundation -framework CoreGraphics \
  -lobjc -lSystem -o build/AndroidNav.arm64.dylib Tweak.m

clang -target arm64e-apple-ios15.0 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
  -fobjc-arc -shared -framework UIKit -framework Foundation -framework CoreGraphics \
  -lobjc -lSystem -o build/AndroidNav.arm64e.dylib Tweak.m

lipo -create build/AndroidNav.arm64.dylib build/AndroidNav.arm64e.dylib -output build/AndroidNav.dylib
ldid -S build/AndroidNav.dylib
```

## Install

Transfer the `.deb` to your device and install via Filza, Sileo, or `dpkg -i`.
