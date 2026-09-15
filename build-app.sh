#!/bin/sh

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output_app=${1:-"${repo_dir}/build/Teams Mute Helper.app"}
sign_identity=${TEAMS_MUTE_SIGN_IDENTITY:--}
architectures=${TEAMS_MUTE_ARCHS:-"arm64 x86_64"}
executable_name="TeamsMuteHelper"
plist="${output_app}/Contents/Info.plist"
executable="${output_app}/Contents/MacOS/${executable_name}"

case "$output_app" in
	/|"${HOME}"|"${HOME}/"|"")
		/usr/bin/printf 'Refusing unsafe output path: %s\n' "$output_app" >&2
		exit 1
		;;
	*.app) ;;
	*)
		/usr/bin/printf 'Output path must end in .app: %s\n' "$output_app" >&2
		exit 1
		;;
esac

if ! /usr/bin/xcrun --sdk macosx --find clang >/dev/null 2>&1; then
	/usr/bin/printf 'Xcode Command Line Tools are required. Run: xcode-select --install\n' >&2
	exit 1
fi

/bin/rm -rf "$output_app"
/bin/mkdir -p "${output_app}/Contents/MacOS" "${output_app}/Contents/Resources"
/bin/cp "${repo_dir}/TeamsMuteHelper-Info.plist" "$plist"
/bin/cp "${repo_dir}/assets/AppIcon.icns" "${output_app}/Contents/Resources/AppIcon.icns"
/bin/cp "${repo_dir}/assets/menu-bar-icon.svg" "${output_app}/Contents/Resources/MenuBarIcon.svg"
/bin/cp "${repo_dir}/assets/menu-bar-icon-pressed.svg" "${output_app}/Contents/Resources/MenuBarIconPressed.svg"
/bin/cp "${repo_dir}/assets/github-mark.svg" "${output_app}/Contents/Resources/GitHubMark.svg"

telemetry_production_build=false
if [ "$sign_identity" != "-" ]; then
	telemetry_production_build=true
fi
/usr/libexec/PlistBuddy -c "Set :TelemetryProductionBuild ${telemetry_production_build}" "$plist"

set --
for architecture in $architectures; do
	set -- "$@" -arch "$architecture"
done

/usr/bin/xcrun --sdk macosx clang \
	-fobjc-arc \
	-O2 \
	-Wall \
	-Wextra \
	-Werror \
	-mmacosx-version-min=13.0 \
	"$@" \
	-framework Cocoa \
	-framework ApplicationServices \
	-framework Carbon \
	-framework ServiceManagement \
	-o "$executable" \
	"${repo_dir}/TeamsMuteHelper.m"

if [ "$sign_identity" = "-" ]; then
	/usr/bin/codesign --force --sign - "$output_app"
else
	/usr/bin/codesign \
		--force \
		--options runtime \
		--timestamp \
		--sign "$sign_identity" \
		"$output_app"
fi

/usr/bin/codesign --verify --strict --verbose=2 "$output_app"
/usr/bin/printf 'Built %s for %s\n' "$output_app" "$architectures"
