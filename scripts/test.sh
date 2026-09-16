#!/bin/sh

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/teams-mute-helper-tests.XXXXXX")
trap '/bin/rm -rf "$test_dir"' EXIT HUP INT TERM
test_binary="${test_dir}/TelemetryTests"

/usr/bin/xcrun --sdk macosx clang \
	-fobjc-arc \
	-O0 \
	-Wall \
	-Wextra \
	-Werror \
	-mmacosx-version-min=13.0 \
	-framework Cocoa \
	-framework ApplicationServices \
	-framework Carbon \
	-framework ServiceManagement \
	-o "$test_binary" \
	"${repo_dir}/tests/TelemetryTests.m"

"$test_binary"
"${repo_dir}/build-app.sh"

test "$(/usr/libexec/PlistBuddy -c 'Print :TelemetryProductionBuild' \
	"${repo_dir}/build/Teams Mute Helper.app/Contents/Info.plist")" = "false"
test -f "${repo_dir}/build/Teams Mute Helper.app/Contents/Resources/MenuBarIconTemplate.png"
test -f "${repo_dir}/build/Teams Mute Helper.app/Contents/Resources/MenuBarIconTemplate@2x.png"
test -f "${repo_dir}/build/Teams Mute Helper.app/Contents/Resources/MenuBarIconPressedTemplate.png"
test -f "${repo_dir}/build/Teams Mute Helper.app/Contents/Resources/MenuBarIconPressedTemplate@2x.png"
test "$(/usr/bin/sips -g pixelWidth \
	"${repo_dir}/build/Teams Mute Helper.app/Contents/Resources/MenuBarIconTemplate.png" | \
	/usr/bin/awk '/pixelWidth/ { print $2 }')" = "18"
test "$(/usr/bin/sips -g pixelWidth \
	"${repo_dir}/build/Teams Mute Helper.app/Contents/Resources/MenuBarIconTemplate@2x.png" | \
	/usr/bin/awk '/pixelWidth/ { print $2 }')" = "36"
test ! -f "${repo_dir}/build/Teams Mute Helper.app/Contents/Resources/MenuBarIcon.svg"
test ! -f "${repo_dir}/build/Teams Mute Helper.app/Contents/Resources/MenuBarIconPressed.svg"
for architecture in arm64 x86_64; do
	/usr/bin/lipo "${repo_dir}/build/Teams Mute Helper.app/Contents/MacOS/TeamsMuteHelper" \
		-verify_arch "$architecture"
done

/usr/bin/printf 'All tests passed\n'
