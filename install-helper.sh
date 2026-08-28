#!/bin/sh

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
install_dir=${TEAMS_MUTE_INSTALL_DIR:-"${HOME}/Applications"}
app_name="Teams Mute Helper.app"
app_path="${install_dir}/${app_name}"
installed_executable="${app_path}/Contents/MacOS/applet"
temp_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/teams-mute-helper.XXXXXX")

cleanup() {
	/bin/rm -rf "$temp_dir"
}
trap cleanup EXIT HUP INT TERM

built_app="${temp_dir}/${app_name}"
plist="${built_app}/Contents/Info.plist"

/usr/bin/osacompile -o "$built_app" "${repo_dir}/teams-mute-helper.applescript"

/usr/libexec/PlistBuddy -c "Delete :CFBundleIdentifier" "$plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string io.github.m-rk.ms-teams-mute-helper" "$plist"

/usr/libexec/PlistBuddy -c "Delete :OSAAppletShowStartupScreen" "$plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :OSAAppletShowStartupScreen bool false" "$plist"

/usr/libexec/PlistBuddy -c "Delete :LSUIElement" "$plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$plist"

for permission_key in \
	NSAppleMusicUsageDescription \
	NSCalendarsUsageDescription \
	NSCameraUsageDescription \
	NSContactsUsageDescription \
	NSHomeKitUsageDescription \
	NSMicrophoneUsageDescription \
	NSPhotoLibraryUsageDescription \
	NSRemindersUsageDescription \
	NSSiriUsageDescription \
	NSSystemAdministrationUsageDescription
do
	/usr/libexec/PlistBuddy -c "Delete :${permission_key}" "$plist" >/dev/null 2>&1 || true
done

/usr/bin/codesign --force --deep --sign - "$built_app"
/bin/mkdir -p "$install_dir"

if [ -e "$app_path" ]; then
	/usr/bin/pkill -f -x "$installed_executable" >/dev/null 2>&1 || true

	backup_dir="${HOME}/Library/Application Support/ms-teams-mute-shortcut/backups"
	timestamp=$(/bin/date +%Y%m%d-%H%M%S)
	/bin/mkdir -p "$backup_dir"
	/bin/mv "$app_path" "${backup_dir}/Teams Mute Helper ${timestamp}.app.backup"
fi

/usr/bin/ditto "$built_app" "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"

/usr/bin/printf 'Installed %s\n' "$app_path"
/usr/bin/printf 'Next: enable Teams Mute Helper in System Settings > Privacy & Security > Accessibility.\n'
