#!/bin/sh

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=${1:-}
version=${version#v}
publish=${2:-}
tag="v${version}"
app_name="Teams Mute Helper.app"
archive_name="Teams-Mute-Helper-${version}.zip"
dist_dir="${repo_dir}/dist"
app_path="${dist_dir}/${app_name}"
archive_path="${dist_dir}/${archive_name}"
checksum_path="${archive_path}.sha256"
notary_archive="${dist_dir}/.notarization.zip"
notary_profile=${TEAMS_MUTE_NOTARY_PROFILE:-teams-mute-helper}

if [ -z "$version" ]; then
	/usr/bin/printf 'Usage: %s VERSION [--publish]\n' "$0" >&2
	exit 1
fi

if [ -n "$publish" ] && [ "$publish" != "--publish" ]; then
	/usr/bin/printf 'Unknown option: %s\n' "$publish" >&2
	exit 1
fi

for command in git security xcrun; do
	if ! command -v "$command" >/dev/null 2>&1; then
		/usr/bin/printf 'Required command not found: %s\n' "$command" >&2
		exit 1
	fi
done

if [ "$publish" = "--publish" ] && ! command -v gh >/dev/null 2>&1; then
	/usr/bin/printf 'GitHub CLI is required to publish a release.\n' >&2
	exit 1
fi

plist_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${repo_dir}/TeamsMuteHelper-Info.plist")
if [ "$plist_version" != "$version" ]; then
	/usr/bin/printf 'Version mismatch: plist contains %s, requested %s\n' "$plist_version" "$version" >&2
	exit 1
fi

if [ -n "$(/usr/bin/git -C "$repo_dir" status --porcelain)" ]; then
	/usr/bin/printf 'Commit the release changes before building a release.\n' >&2
	exit 1
fi

sign_identity=${TEAMS_MUTE_SIGN_IDENTITY:-$(
	/usr/bin/security find-identity -v -p codesigning |
		/usr/bin/sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' |
		/usr/bin/head -n 1
)}
if [ -z "$sign_identity" ]; then
	/usr/bin/printf 'No Developer ID Application certificate is installed.\n' >&2
	exit 1
fi

/bin/rm -rf "$dist_dir"
/bin/mkdir -p "$dist_dir"
TEAMS_MUTE_ARCHS="arm64 x86_64" \
	TEAMS_MUTE_SIGN_IDENTITY="$sign_identity" \
	"${repo_dir}/build-app.sh" "$app_path"

/usr/bin/lipo "${app_path}/Contents/MacOS/TeamsMuteHelper" -verify_arch arm64 x86_64
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$notary_archive"
/usr/bin/xcrun notarytool submit "$notary_archive" --keychain-profile "$notary_profile" --wait
/usr/bin/xcrun stapler staple "$app_path"
/usr/bin/xcrun stapler validate "$app_path"
/usr/sbin/spctl --assess --type execute --verbose=4 "$app_path"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"
(
	cd "$dist_dir"
	/usr/bin/shasum -a 256 "$archive_name" > "${archive_name}.sha256"
)
/bin/rm -f "$notary_archive"

/usr/bin/printf 'Created notarized release artifacts:\n%s\n%s\n' "$archive_path" "$checksum_path"

if [ "$publish" = "--publish" ]; then
	if ! /usr/bin/git -C "$repo_dir" rev-parse --verify --quiet "refs/tags/${tag}" >/dev/null; then
		/usr/bin/git -C "$repo_dir" tag -a "$tag" -m "Teams Mute Helper ${version}"
	fi
	/usr/bin/git -C "$repo_dir" push origin "$tag"
	gh release create "$tag" \
			"$archive_path" \
			"$checksum_path" \
			--repo m-rk/ms-teams-mute-shortcut \
			--title "Teams Mute Helper ${version}" \
			--generate-notes \
			--verify-tag
fi
