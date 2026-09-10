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
legacy_launch_agent="${HOME}/Library/LaunchAgents/${bundle_id}.plist"
legacy_service="gui/$(/usr/bin/id -u)/${bundle_id}"
launch_app=${TEAMS_MUTE_LAUNCH_LISTENER:-1}
migrate_legacy_login_item=${TEAMS_MUTE_MIGRATE_LEGACY_LOGIN_ITEM:-1}
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

stop_legacy_login_item() {
	if [ "$migrate_legacy_login_item" = "0" ]; then
		return
	fi
	/bin/launchctl bootout "$legacy_service" >/dev/null 2>&1 || true
	/bin/rm -f "$legacy_launch_agent"
}

stop_running_helper() {
	/usr/bin/pkill -f -x "$installed_executable --listen --verbose" >/dev/null 2>&1 || true
	/usr/bin/pkill -f -x "$installed_executable --listen" >/dev/null 2>&1 || true
	/usr/bin/pkill -f -x "$installed_executable" >/dev/null 2>&1 || true
	/usr/bin/pkill -f -x "$legacy_executable" >/dev/null 2>&1 || true
}

if [ "${1:-}" = "--uninstall" ]; then
	if [ -x "$installed_executable" ]; then
		"$installed_executable" --unregister-login-item >/dev/null 2>&1 || true
	fi
	stop_legacy_login_item
	stop_running_helper
	if [ -e "$app_path" ]; then
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
TEAMS_MUTE_ARCHS="${TEAMS_MUTE_ARCHS:-arm64 x86_64}" \
	TEAMS_MUTE_SIGN_IDENTITY="${TEAMS_MUTE_SIGN_IDENTITY:--}" \
	"${repo_dir}/build-app.sh" "$built_app"

/bin/mkdir -p "$install_dir"
stop_legacy_login_item
stop_running_helper

if [ -e "$app_path" ]; then
	"$lsregister" -u "$app_path" >/dev/null 2>&1 || true
	/bin/rm -rf "$app_path"
fi

/usr/bin/ditto "$built_app" "$app_path"
/usr/bin/codesign --verify --strict "$app_path"
"$lsregister" -f "$app_path" >/dev/null 2>&1 || true

if [ "$launch_app" != "0" ]; then
	/usr/bin/open "$app_path"
fi

/usr/bin/printf 'Installed %s\n' "$app_path"
if [ "$launch_app" != "0" ]; then
	/usr/bin/printf 'Started the helper; it will register its native login item.\n'
fi
/usr/bin/printf 'Next: enable Teams Mute Helper in System Settings > Privacy & Security > Accessibility.\n'
