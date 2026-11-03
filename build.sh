#!/bin/zsh
set -eu
cd -- "${0:A:h}"
build_dir="$PWD/build"
app_dir="$build_dir/内存提醒.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$build_dir/module-cache"
xcrun clang -O2 -Wall -Wextra -mmacosx-version-min=13.0 -c Sources/SystemProbe.c -o "$build_dir/SystemProbe.o"
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -module-cache-path "$build_dir/module-cache" \
    -import-objc-header Sources/SystemProbe.h -framework AppKit -framework SwiftUI -framework ServiceManagement \
    Sources/Rules.swift Sources/Monitor.swift Sources/Views.swift Sources/main.swift "$build_dir/SystemProbe.o" \
    -o "$app_dir/Contents/MacOS/MemoryGuardMenu"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MemoryGuardMenu</string>
<key>CFBundleIdentifier</key><string>com.samuelzhao.memory-guard-menu</string>
<key>CFBundleName</key><string>内存提醒</string>
<key>CFBundleDisplayName</key><string>内存提醒</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$app_dir/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app_dir"
/usr/bin/codesign --verify --strict "$app_dir"
xcrun swiftc -O -swift-version 5 -module-cache-path "$build_dir/module-cache" Sources/Rules.swift Tests/main.swift -o "$build_dir/rule-tests"
"$build_dir/rule-tests"
print "已构建：$app_dir"
