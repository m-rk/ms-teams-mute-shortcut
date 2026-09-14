#!/bin/sh

set -eu

usage() {
	/usr/bin/printf 'Usage: %s --check | VERSION SHA256\n' "$0" >&2
	exit 1
}

for command in git brew; do
	if ! command -v "$command" >/dev/null 2>&1; then
		/usr/bin/printf 'Required command not found: %s\n' "$command" >&2
		exit 1
	fi
done

if ! tap_dir=$(brew --repository m-rk/tap 2>/dev/null); then
	/usr/bin/printf 'Homebrew tap m-rk/tap is not installed. Run: brew tap m-rk/tap\n' >&2
	exit 1
fi
cask_relative_path="Casks/teams-mute-helper.rb"
cask_path="${tap_dir}/${cask_relative_path}"

if [ ! -d "${tap_dir}/.git" ] || [ ! -f "$cask_path" ]; then
	/usr/bin/printf 'Homebrew tap checkout not found at %s.\n' "$tap_dir" >&2
	/usr/bin/printf 'Run brew tap m-rk/tap to install it.\n' >&2
	exit 1
fi

branch=$(/usr/bin/git -C "$tap_dir" symbolic-ref --quiet --short HEAD || true)
if [ "$branch" != "main" ]; then
	/usr/bin/printf 'Homebrew tap must be on main; found %s.\n' "${branch:-detached HEAD}" >&2
	exit 1
fi

if [ -n "$(/usr/bin/git -C "$tap_dir" status --porcelain)" ]; then
	/usr/bin/printf 'Homebrew tap contains local changes; commit or remove them first.\n' >&2
	exit 1
fi

/usr/bin/git -C "$tap_dir" fetch --prune origin "+refs/heads/main:refs/remotes/origin/main"
local_head=$(/usr/bin/git -C "$tap_dir" rev-parse HEAD)
remote_head=$(/usr/bin/git -C "$tap_dir" rev-parse refs/remotes/origin/main)
if [ "$local_head" != "$remote_head" ]; then
	/usr/bin/git -C "$tap_dir" merge --ff-only refs/remotes/origin/main
fi

if [ "${1:-}" = "--check" ]; then
	if [ "$#" -ne 1 ]; then
		usage
	fi
	/usr/bin/printf 'Homebrew tap is ready at %s.\n' "$tap_dir"
	exit 0
fi

if [ "$#" -ne 2 ]; then
	usage
fi

version=${1#v}
checksum=$2
if ! /usr/bin/printf '%s\n' "$version" | /usr/bin/grep -Eq '^[0-9]+(\.[0-9]+){2}$'; then
	usage
fi
if [ "${#checksum}" -ne 64 ] || [ -n "$(/usr/bin/printf '%s' "$checksum" | /usr/bin/tr -d '0-9a-f')" ]; then
	/usr/bin/printf 'SHA256 must be 64 lowercase hexadecimal characters.\n' >&2
	exit 1
fi

current_version=$(/usr/bin/sed -n 's/^  version "\([^"]*\)"$/\1/p' "$cask_path")
current_checksum=$(/usr/bin/sed -n 's/^  sha256 "\([^"]*\)"$/\1/p' "$cask_path")
if [ -z "$current_version" ] || [ -z "$current_checksum" ]; then
	/usr/bin/printf 'Could not read the current version and checksum from %s.\n' "$cask_path" >&2
	exit 1
fi

if [ "$current_version" != "$version" ] || [ "$current_checksum" != "$checksum" ]; then
	temporary_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/teams-mute-cask.XXXXXX")
	temporary_cask="${temporary_dir}/teams-mute-helper.rb"
	original_cask="${temporary_dir}/teams-mute-helper.original.rb"
	cleanup() {
		/bin/rm -rf "$temporary_dir"
	}
	trap cleanup EXIT HUP INT TERM
	/bin/cp -p "$cask_path" "$original_cask"

	/usr/bin/awk -v version="$version" -v checksum="$checksum" '
		/^  version "[^"]*"$/ { print "  version \"" version "\""; next }
		/^  sha256 "[^"]*"$/ { print "  sha256 \"" checksum "\""; next }
		{ print }
	' "$cask_path" > "$temporary_cask"

	/bin/chmod 644 "$temporary_cask"
	/bin/mv "$temporary_cask" "$cask_path"
	if ! brew style --cask m-rk/tap/teams-mute-helper; then
		/bin/cp -p "$original_cask" "$cask_path"
		exit 1
	fi
	trap - EXIT HUP INT TERM
	cleanup

	/usr/bin/git -C "$tap_dir" diff --check -- "$cask_relative_path"
	/usr/bin/git -C "$tap_dir" add -- "$cask_relative_path"
	/usr/bin/git -C "$tap_dir" commit -m "Update Teams Mute Helper cask to ${version}"
	/usr/bin/git -C "$tap_dir" push origin main
else
	/usr/bin/printf 'Homebrew cask already contains Teams Mute Helper %s.\n' "$version"
fi

brew update
brew audit --cask --online m-rk/tap/teams-mute-helper
brew reinstall --cask m-rk/tap/teams-mute-helper

installed_app="/Applications/Teams Mute Helper.app"
installed_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
	"${installed_app}/Contents/Info.plist")
if [ "$installed_version" != "$version" ]; then
	/usr/bin/printf 'Installed app version mismatch: expected %s, found %s.\n' \
		"$version" "$installed_version" >&2
	exit 1
fi
/usr/bin/codesign --verify --strict --verbose=2 "$installed_app"
/usr/sbin/spctl --assess --type execute --verbose=4 "$installed_app"
/usr/bin/open -a "Teams Mute Helper"
