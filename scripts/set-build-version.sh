#!/usr/bin/env bash
#
# Write the firmware version and image name options into a .config.
#
# Image names follow include/image.mk:
#   IMG_PREFIX = DIST + [VERSION_NUMBER] + [VERSION_CODE] + [EXTRA_IMAGE_NAME] + BOARD-SUBTARGET
# Only VERSION_NUMBER ("<date>-<commit>") goes into the file name by default;
# the full build id ("<date>-<commit>-<upstream commit>") is stored in
# VERSION_CODE and shows up in /etc/openwrt_release and LuCI.
#
# Environment overrides:
#   VERSION_DIST            distribution name (default "OpenWrt", plus the
#                           device name derived from CONFIG_TARGET_PROFILE)
#   BUILD_TZ                time zone of the build date (default Asia/Taipei)
#   BUILD_DATE              build date as YYYYMMDD (default: today)
#   REPO_COMMIT / UPSTREAM_COMMIT / BUILD_ID
#   UPSTREAM_REF            upstream branch to compute the merge base against
#                           (default upstream/main)
#   COMMIT_LEN              abbreviated commit length (default 8)
#   VERSION_NUMBER / VERSION_CODE / EXTRA_IMAGE_NAME
#   VERSION_FILENAMES       put VERSION_NUMBER into file names (default y)
#   VERSION_CODE_FILENAMES  put VERSION_CODE into file names (default unset)

set -euo pipefail

config_file="${1:-.config}"

if [[ ! -f "$config_file" ]]; then
	echo "config file not found: $config_file" >&2
	exit 1
fi

# DEVICE_ltc_vl7m19k -> LTC_VL7M19K
detect_device_model() {
	local profile
	profile="$(sed -n -e 's/^CONFIG_TARGET_PROFILE="\(.*\)"$/\1/p' "$config_file" | head -n 1)"
	# A seed config only carries the device symbol before make defconfig
	[[ -n "$profile" ]] || profile="$(sed -n -e 's/^CONFIG_TARGET_[a-z0-9]*_[a-z0-9]*_DEVICE_\(.*\)=y$/DEVICE_\1/p' "$config_file" | head -n 1)"
	[[ "$profile" =~ ^DEVICE_([A-Za-z0-9_+-]+)$ ]] || return 1
	printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]'
}

is_true() {
	case "${1:-}" in
		1|y|Y|yes|YES|true|TRUE|on|ON) return 0 ;;
		*) return 1 ;;
	esac
}

# Same as the sanitize in include/version.mk
sanitize() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr ' _' '--'
}

config_get_string() {
	sed -n -e "s/^$1=\"\(.*\)\"$/\1/p" "$config_file" | head -n 1
}

escape_config_string() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

device_model="$(detect_device_model || true)"
version_dist="${VERSION_DIST:-OpenWrt${device_model:+ $device_model}}"
build_tz="${BUILD_TZ:-Asia/Taipei}"
commit_len="${COMMIT_LEN:-8}"
upstream_ref="${UPSTREAM_REF:-upstream/main}"
version_filenames="${VERSION_FILENAMES:-y}"
version_code_filenames="${VERSION_CODE_FILENAMES:-}"

build_date="${BUILD_DATE:-$(TZ="$build_tz" date +'%Y%m%d')}"

repo_commit="${REPO_COMMIT:-}"
if [[ -z "$repo_commit" ]]; then
	repo_commit="$(git rev-parse --short="$commit_len" HEAD 2>/dev/null || true)"
fi
repo_commit="${repo_commit:-unknown}"

upstream_commit="${UPSTREAM_COMMIT:-}"
if [[ -z "$upstream_commit" ]] && git rev-parse --verify "$upstream_ref" >/dev/null 2>&1; then
	upstream_base="$(git merge-base HEAD "$upstream_ref" 2>/dev/null || true)"
	if [[ -n "$upstream_base" ]]; then
		upstream_commit="$(git rev-parse --short="$commit_len" "$upstream_base")"
	fi
fi
upstream_commit="${upstream_commit:-unknown}"

build_id="${BUILD_ID:-${build_date}-${repo_commit}-${upstream_commit}}"
version_number="${VERSION_NUMBER:-${build_date}-${repo_commit}}"
version_code="${VERSION_CODE:-${build_id}}"
extra_image_name="${EXTRA_IMAGE_NAME:-}"

if is_true "$version_filenames"; then
	cfg_version_filenames='CONFIG_VERSION_FILENAMES=y'
else
	cfg_version_filenames='# CONFIG_VERSION_FILENAMES is not set'
fi

if is_true "$version_code_filenames"; then
	cfg_version_code_filenames='CONFIG_VERSION_CODE_FILENAMES=y'
else
	cfg_version_code_filenames='# CONFIG_VERSION_CODE_FILENAMES is not set'
fi

tmp_file="${config_file}.version.$$"
trap 'rm -f "$tmp_file"' EXIT

sed -E \
	-e '/^CONFIG_(IMAGEOPT|EXTRA_IMAGE_NAME|VERSIONOPT|VERSION_DIST|VERSION_NUMBER|VERSION_CODE|VERSION_FILENAMES|VERSION_CODE_FILENAMES)=/d' \
	-e '/^# CONFIG_(IMAGEOPT|EXTRA_IMAGE_NAME|VERSIONOPT|VERSION_DIST|VERSION_NUMBER|VERSION_CODE|VERSION_FILENAMES|VERSION_CODE_FILENAMES) is not set$/d' \
	"$config_file" > "$tmp_file"

cat >> "$tmp_file" <<EOF
CONFIG_IMAGEOPT=y
CONFIG_EXTRA_IMAGE_NAME="$(escape_config_string "$extra_image_name")"
CONFIG_VERSIONOPT=y
CONFIG_VERSION_DIST="$(escape_config_string "$version_dist")"
CONFIG_VERSION_NUMBER="$(escape_config_string "$version_number")"
CONFIG_VERSION_CODE="$(escape_config_string "$version_code")"
$cfg_version_filenames
$cfg_version_code_filenames
EOF

mv "$tmp_file" "$config_file"
trap - EXIT

img_prefix="$(sanitize "$version_dist")"
is_true "$version_filenames" && img_prefix="${img_prefix}-$(sanitize "$version_number")"
is_true "$version_code_filenames" && img_prefix="${img_prefix}-$(sanitize "$version_code")"
[[ -n "$extra_image_name" ]] && img_prefix="${img_prefix}-$(sanitize "$extra_image_name")"
board="$(config_get_string CONFIG_TARGET_BOARD)"
subtarget="$(config_get_string CONFIG_TARGET_SUBTARGET)"
[[ -n "$board" ]] && img_prefix="${img_prefix}-${board}"
[[ -n "$subtarget" ]] && img_prefix="${img_prefix}-${subtarget}"

echo "Configured firmware version: ${version_dist} ${version_number}"
echo "Configured firmware revision: ${version_code}"
echo "Configured image name prefix: ${img_prefix}"
