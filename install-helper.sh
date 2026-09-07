#!/bin/sh

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
install_dir=${TEAMS_MUTE_INSTALL_DIR:-"${HOME}/Applications"}
app_name="Teams Mute Helper.app"
app_path="${install_dir}/${app_name}"
executable_name="TeamsMuteHelper"
installed_executable="${app_path}/Contents/MacOS/${executable_name}"
legacy_executable="${app_path}/Contents/MacOS/applet"
bundle_id="io.github.m-rk.ms-teams-mute-helper"
launch_agents_dir="${HOME}/Library/LaunchAgents"
launch_agent_path="${launch_agents_dir}/${bundle_id}.plist"
service_domain="gui/$(/usr/bin/id -u)"
service_target="${service_domain}/${bundle_id}"
launch_listener=${TEAMS_MUTE_LAUNCH_LISTENER:-1}
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [ "${1:-}" = "--uninstall" ]; then
	/bin/launchctl bootout "$service_target" >/dev/null 2>&1 || true
	/bin/rm -f "$launch_agent_path"
	if [ -e "$app_path" ]; then
		/usr/bin/pkill -f -x "$installed_executable --listen" >/dev/null 2>&1 || true
		/usr/bin/pkill -f -x "$installed_executable" >/dev/null 2>&1 || true
		"$lsregister" -u "$app_path" >/dev/null 2>&1 || true
		/bin/rm -rf "$app_path"
	fi
	/usr/bin/printf 'Removed Teams Mute Helper and its login item.\n'
	exit 0
fi

temp_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/teams-mute-helper.XXXXXX")

cleanup() {
	/bin/rm -rf "$temp_dir"
}
trap cleanup EXIT HUP INT TERM

built_app="${temp_dir}/${app_name}"
plist="${built_app}/Contents/Info.plist"
built_executable="${built_app}/Contents/MacOS/${executable_name}"
icon="${built_app}/Contents/Resources/AppIcon.icns"
built_launch_agent="${temp_dir}/${bundle_id}.plist"

if ! /usr/bin/xcrun --sdk macosx --find clang >/dev/null 2>&1; then
	/usr/bin/printf 'Xcode Command Line Tools are required. Run: xcode-select --install\n' >&2
	exit 1
fi

/bin/mkdir -p "${built_app}/Contents/MacOS" "${built_app}/Contents/Resources"
/bin/cp "${repo_dir}/TeamsMuteHelper-Info.plist" "$plist"
/bin/cp "${repo_dir}/assets/AppIcon.icns" "$icon"
/usr/bin/xcrun --sdk macosx clang \
	-fobjc-arc \
	-O2 \
	-Wall \
	-Wextra \
	-Werror \
	-mmacosx-version-min=13.0 \
	-framework Cocoa \
	-framework ApplicationServices \
	-framework Carbon \
	-o "$built_executable" \
	"${repo_dir}/TeamsMuteHelper.m"

/usr/bin/codesign --force --deep --sign - "$built_app"

/usr/libexec/PlistBuddy -c 'Clear dict' "$built_launch_agent" >/dev/null
/usr/libexec/PlistBuddy -c "Add :Label string $bundle_id" "$built_launch_agent"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$built_launch_agent"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $installed_executable" "$built_launch_agent"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:1 string --listen' "$built_launch_agent"
/usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "$built_launch_agent"
/usr/libexec/PlistBuddy -c 'Add :KeepAlive dict' "$built_launch_agent"
/usr/libexec/PlistBuddy -c 'Add :KeepAlive:SuccessfulExit bool false' "$built_launch_agent"
/usr/libexec/PlistBuddy -c 'Add :LimitLoadToSessionType string Aqua' "$built_launch_agent"

/bin/mkdir -p "$install_dir"

if [ "$launch_listener" != "0" ]; then
	/bin/launchctl bootout "$service_target" >/dev/null 2>&1 || true
fi

if [ -e "$app_path" ]; then
	/usr/bin/pkill -f -x "$installed_executable --listen" >/dev/null 2>&1 || true
	/usr/bin/pkill -f -x "$installed_executable" >/dev/null 2>&1 || true
	/usr/bin/pkill -f -x "$legacy_executable" >/dev/null 2>&1 || true
	"$lsregister" -u "$app_path" >/dev/null 2>&1 || true
	/bin/rm -rf "$app_path"
fi

/usr/bin/ditto "$built_app" "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"
"$lsregister" -f "$app_path" >/dev/null 2>&1 || true

if [ "$launch_listener" != "0" ]; then
	/bin/mkdir -p "$launch_agents_dir"
	/bin/cp "$built_launch_agent" "$launch_agent_path"
	/bin/chmod 0644 "$launch_agent_path"
	/bin/launchctl bootstrap "$service_domain" "$launch_agent_path"
fi

/usr/bin/printf 'Installed %s\n' "$app_path"
if [ "$launch_listener" != "0" ]; then
	/usr/bin/printf 'Started the Control-Shift-Command-A listener and added it to login items.\n'
fi
/usr/bin/printf 'Next: enable Teams Mute Helper in System Settings > Privacy & Security > Accessibility.\n'
