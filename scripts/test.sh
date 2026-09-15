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
test -f "${repo_dir}/build/Teams Mute Helper.app/Contents/Resources/MenuBarIcon.svg"
test -f "${repo_dir}/build/Teams Mute Helper.app/Contents/Resources/MenuBarIconPressed.svg"
/usr/bin/lipo "${repo_dir}/build/Teams Mute Helper.app/Contents/MacOS/TeamsMuteHelper" \
	-verify_arch arm64 x86_64

/usr/bin/printf 'All tests passed\n'
