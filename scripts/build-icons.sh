#!/bin/sh

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
assets_dir="${repo_dir}/assets"
temporary_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/teams-mute-icons.XXXXXX")
iconset_dir="${temporary_dir}/AppIcon.iconset"
rendered_dir="${temporary_dir}/rendered"

cleanup() {
	/bin/rm -rf "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM

for command in qlmanage sips iconutil xcrun; do
	if ! command -v "$command" >/dev/null 2>&1; then
		/usr/bin/printf 'Required command not found: %s\n' "$command" >&2
		exit 1
	fi
done

/bin/mkdir -p "$iconset_dir" "$rendered_dir"

/usr/bin/qlmanage -t -s 1024 -o "$rendered_dir" "${assets_dir}/app-icon.svg" >/dev/null 2>&1
/bin/cp "${rendered_dir}/app-icon.svg.png" "${assets_dir}/app-icon.png"
/usr/bin/xcrun swift \
	-module-cache-path "${temporary_dir}/swift-module-cache" \
	"${repo_dir}/scripts/render-template-icon.swift" \
	"${assets_dir}/menu-bar-icon.svg" \
	"${assets_dir}/menu-bar-icon.png" \
	1024
/usr/bin/xcrun swift \
	-module-cache-path "${temporary_dir}/swift-module-cache" \
	"${repo_dir}/scripts/render-template-icon.swift" \
	"${assets_dir}/menu-bar-icon-pressed.svg" \
	"${assets_dir}/menu-bar-icon-pressed.png" \
	1024

for specification in \
	"16 icon_16x16.png" \
	"32 icon_16x16@2x.png" \
	"32 icon_32x32.png" \
	"64 icon_32x32@2x.png" \
	"128 icon_128x128.png" \
	"256 icon_128x128@2x.png" \
	"256 icon_256x256.png" \
	"512 icon_256x256@2x.png" \
	"512 icon_512x512.png" \
	"1024 icon_512x512@2x.png"
do
	set -- $specification
	size=$1
	filename=$2
	/usr/bin/sips -z "$size" "$size" "${assets_dir}/app-icon.png" \
		--out "${iconset_dir}/${filename}" >/dev/null
done

/usr/bin/iconutil -c icns "$iconset_dir" -o "${assets_dir}/AppIcon.icns"
/usr/bin/printf 'Updated app and menu-bar icon assets.\n'
