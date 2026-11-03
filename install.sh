#!/bin/zsh
set -eu
cd -- "${0:A:h}"
source_app="$PWD/build/内存提醒.app"
target_app="$HOME/Applications/内存提醒.app"
if [[ ! -x "$source_app/Contents/MacOS/MemoryGuardMenu" ]]; then
    zsh build.sh
fi
mkdir -p "$HOME/Applications"
if [[ -e "$target_app" ]]; then
    identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$target_app/Contents/Info.plist")
    if [[ "$identifier" != "com.samuelzhao.memory-guard-menu" ]]; then
        print -u2 '目标位置已有其他应用，安装已停止。'
        exit 1
    fi
    backup_dir="$PWD/backups/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    /usr/bin/ditto "$target_app" "$backup_dir/内存提醒.app"
    "$target_app/Contents/MacOS/MemoryGuardMenu" --quit-running
    # Only our identified app can be stopped; never force quit any process.
    for attempt in {1..20}; do
        if ! /usr/bin/pgrep -f "^${target_app}/Contents/MacOS/MemoryGuardMenu" >/dev/null; then break; fi
        /bin/sleep 0.25
    done
    if /usr/bin/pgrep -f "^${target_app}/Contents/MacOS/MemoryGuardMenu" >/dev/null; then
        print -u2 '旧版仍在运行，请从菜单退出后重新安装。备份已保留。'
        exit 1
    fi
fi
/usr/bin/ditto "$source_app" "$target_app"
/usr/bin/codesign --verify --strict "$target_app"
/usr/bin/open "$target_app" --args --show-window
print "已安装并打开：$target_app"
print '登录自启动默认关闭，可在应用设置中打开。'
