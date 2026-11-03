#!/bin/zsh
set -eu
cd -- "${0:A:h}"
build_dir="$PWD/build"
fixture="$build_dir/MemoryGuardFixture.app"
mkdir -p "$fixture/Contents/MacOS" "$build_dir/module-cache"
xcrun swiftc -O -swift-version 5 -module-cache-path "$build_dir/module-cache" -framework AppKit \
    Tests/Fixture/main.swift -o "$fixture/Contents/MacOS/MemoryGuardFixture"
cat > "$fixture/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MemoryGuardFixture</string>
<key>CFBundleIdentifier</key><string>com.samuelzhao.memory-guard-fixture</string>
<key>CFBundleName</key><string>MemoryGuardFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><false/>
</dict></plist>
PLIST
codesign --force --sign - "$fixture"
xcrun swiftc -O -swift-version 5 -module-cache-path "$build_dir/module-cache" -import-objc-header Sources/SystemProbe.h \
    -framework AppKit -framework SwiftUI -framework ServiceManagement \
    Sources/Rules.swift Sources/Monitor.swift Tests/Integration/main.swift "$build_dir/SystemProbe.o" \
    -o "$build_dir/integration-tests"
"$build_dir/integration-tests" "$build_dir"
