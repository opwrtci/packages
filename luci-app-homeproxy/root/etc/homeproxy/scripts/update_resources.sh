#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2025 ImmortalWrt.org

NAME="homeproxy"

RESOURCES_DIR="${RESOURCES_DIR:-/etc/$NAME/resources}"
DASHBOARD_DIR="${DASHBOARD_DIR:-/etc/$NAME/dashboard}"
RUN_DIR="${RUN_DIR:-/var/run/$NAME}"
LOG_PATH="$RUN_DIR/$NAME.log"
RESULT_PATH="$RUN_DIR/update_resources.result"
RULESET_PROVIDER="${RULESET_PROVIDER:-}"
if [ -z "$RULESET_PROVIDER" ]; then
	RULESET_PROVIDER="$(/sbin/uci -q get homeproxy.config.ruleset_provider 2>/dev/null || /sbin/uci -q get homeproxy.resources.ruleset_provider 2>/dev/null || echo "metacubex")"
fi
[ -z "$RULESET_PROVIDER" ] && RULESET_PROVIDER="metacubex"

if [ "$RULESET_PROVIDER" = "sagernet" ]; then
	DEFAULT_GEOIP_SOURCE="https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.srs"
	DEFAULT_GEOIP_VERSION_URL="https://github.com/SagerNet/sing-geoip/releases/latest"
	DEFAULT_GEOSITE_SOURCE="https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set-unstable/geosite-cn.srs"
	DEFAULT_GEOSITE_VERSION_URL="https://github.com/SagerNet/sing-geosite/releases/latest"
else
	DEFAULT_GEOIP_SOURCE="https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/cn.srs"
	DEFAULT_GEOIP_VERSION_URL="https://github.com/MetaCubeX/meta-rules-dat/commits/sing.atom"
	DEFAULT_GEOSITE_SOURCE="https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/cn.srs"
	DEFAULT_GEOSITE_VERSION_URL="https://github.com/MetaCubeX/meta-rules-dat/commits/sing.atom"
fi

GEOIP_SOURCE="${GEOIP_SOURCE:-$DEFAULT_GEOIP_SOURCE}"
GEOIP_VERSION_URL="${GEOIP_VERSION_URL:-$DEFAULT_GEOIP_VERSION_URL}"
GEOSITE_SOURCE="${GEOSITE_SOURCE:-$DEFAULT_GEOSITE_SOURCE}"
GEOSITE_VERSION_URL="${GEOSITE_VERSION_URL:-$DEFAULT_GEOSITE_VERSION_URL}"
DASHBOARD_SOURCE="${DASHBOARD_SOURCE:-https://codeload.github.com/SagerNet/sing-box-dashboard/zip/refs/heads/gh-pages}"
DASHBOARD_VERSION_URL="${DASHBOARD_VERSION_URL:-https://github.com/SagerNet/sing-box-dashboard/commits/gh-pages.atom}"
USER_AGENT="HomeProxy resource updater"
UPDATE_PROXY="${HOMEPROXY_UPDATE_PROXY:-}"
SING_BOX="${SING_BOX:-/usr/bin/sing-box}"

if ! mkdir -p "$RESOURCES_DIR" "$DASHBOARD_DIR" "$RUN_DIR"; then
	printf '%s\n' "Failed to prepare HomeProxy resource directories." >&2
	exit 1
fi

log() {
	printf '%s %s\n' "$(date "+%Y-%m-%d %H:%M:%S")" "$*" >> "$LOG_PATH"
}

UPDATED_BRANCHES=""
FAILED_BRANCHES=""
CORE_UPDATED=0
DASHBOARD_UPDATED=0

mark_updated() {
	UPDATED_BRANCHES="${UPDATED_BRANCHES:+$UPDATED_BRANCHES,}$1"
	case "$1" in
	dashboard) DASHBOARD_UPDATED=1 ;;
	*) CORE_UPDATED=1 ;;
	esac
}

mark_failed() {
	FAILED_BRANCHES="${FAILED_BRANCHES:+$FAILED_BRANCHES,}$1"
}

finish() {
	printf 'status=%s\ncore_updated=%s\ndashboard_updated=%s\napply_failed=%s\nupdated=%s\nfailed=%s\n' \
		"$1" "$CORE_UPDATED" "$DASHBOARD_UPDATED" "$APPLY_FAILED" \
		"$UPDATED_BRANCHES" "$FAILED_BRANCHES" > "$RESULT_PATH"
	exit "$1"
}

run_curl() {
	if [ -n "$UPDATE_PROXY" ]; then
		/usr/bin/curl --proxy "$UPDATE_PROXY" "$@"
	else
		/usr/bin/curl "$@"
	fi
}

download() {
	run_curl -fsSL --compressed --retry 3 --retry-all-errors --retry-delay 1 \
		--connect-timeout 10 --max-time 60 -A "$USER_AGENT" -o "$2" "$1" &&
		test -s "$2"
}

validate_rule_set() {
	"$SING_BOX" rule-set match -f binary "$1" 192.0.2.1 >/dev/null 2>&1
}

fetch_version() {
	local url="$1"
	case "$url" in
	*.atom)
		local feed version
		feed="$(run_curl -fsSL --compressed --retry 3 --retry-all-errors \
			--retry-delay 1 --connect-timeout 10 --max-time 30 \
			-A "$USER_AGENT" "$url")" || return 1
		version="$(printf '%s\n' "$feed" | awk -F '[<>]' '
			/<updated>/ {
				version = $3
				gsub(/[-:TZ]/, "", version)
				print version
				exit
			}
		')"
		case "$version" in
		??????????????) case "$version" in *[!0-9]*) return 1 ;; esac ;;
		*) return 1 ;;
		esac
		printf '%s\n' "$version"
		;;
	*)
		local effective_url version
		effective_url="$(run_curl -fsSL --compressed --retry 3 --retry-all-errors \
			--retry-delay 1 --connect-timeout 10 --max-time 30 \
			-A "$USER_AGENT" -o /dev/null -w '%{url_effective}' "$url")" || return 1
		version="${effective_url##*/}"
		case "$version" in
		''|*[!0-9]*) return 1 ;;
		esac
		printf '%s\n' "$version"
		;;
	esac
}

fetch_release_version() {
	fetch_version "$1"
}

fetch_dashboard_version() {
	fetch_version "$DASHBOARD_VERSION_URL"
}

versioned_url() {
	case "$1" in
	http://*|https://*) printf '%s?v=%s' "$1" "$2" ;;
	*) printf '%s' "$1" ;;
	esac
}

install_rule_set() {
	local source_file="$1" version="$2" resource="$3"
	local stage_dir="$RESOURCES_DIR/.update.$$.tmp"

	mkdir -p "$stage_dir" &&
		cp "$source_file" "$stage_dir/$resource.srs" &&
		printf '%s\n' "$version" > "$stage_dir/$resource.ver" &&
		printf '%s\n' "$RULESET_PROVIDER" > "$stage_dir/.ruleset_provider" &&
		chmod 0644 "$stage_dir/$resource.srs" "$stage_dir/$resource.ver" "$stage_dir/.ruleset_provider" &&
		mv -f "$stage_dir/$resource.srs" "$RESOURCES_DIR/$resource.srs" || return 1
	mark_updated "$resource"
	mv -f "$stage_dir/$resource.ver" "$RESOURCES_DIR/$resource.ver"
	mv -f "$stage_dir/.ruleset_provider" "$RESOURCES_DIR/.ruleset_provider"
}

update_rule_set() {
	local resource="$1" source_url="$2" version_url="$3"
	local version old_version old_provider

	old_provider="$(cat "$RESOURCES_DIR/.ruleset_provider" 2>/dev/null)"
	if [ -n "$old_provider" ] && [ "$old_provider" != "$RULESET_PROVIDER" ]; then
		log "[$resource] Rule-set provider changed ($old_provider -> $RULESET_PROVIDER), forcing refresh."
		rm -f "$RESOURCES_DIR/$resource.ver"
	fi

	if ! version="$(fetch_version "$version_url")"; then
		log "[$resource] Failed to get the latest version; continuing with other resources."
		return 1
	fi
	old_version="$(cat "$RESOURCES_DIR/$resource.ver" 2>/dev/null)"
	if [ "$old_version" = "$version" ] && validate_rule_set "$RESOURCES_DIR/$resource.srs"; then
		log "[$resource] Current version: $version ($RULESET_PROVIDER)."
		return 0
	fi
	log "[$resource] Local version: ${old_version:-NOT FOUND}, latest version: $version ($RULESET_PROVIDER)."
	log "[$resource] Downloading rule set from $(versioned_url "$source_url" "$version")..."
	if ! download "$(versioned_url "$source_url" "$version")" "$TMP_DIR/$resource.srs"; then
		log "[$resource] Update failed while downloading the rule set."
		return 1
	fi
	log "[$resource] Validating binary rule set format..."
	if ! validate_rule_set "$TMP_DIR/$resource.srs"; then
		log "[$resource] Update failed: invalid binary rule set."
		return 1
	fi
	if ! install_rule_set "$TMP_DIR/$resource.srs" "$version" "$resource"; then
		log "[$resource] Update failed while installing the rule set."
		return 1
	fi
	log "[$resource] Successfully updated."
}

update_dashboard() {
	local version old_version index source_dir=""
	local backup_dir="${DASHBOARD_DIR}.old.$$"

	if ! version="$(fetch_dashboard_version)"; then
		log "[dashboard] Failed to get the latest version; continuing with other resources."
		return 1
	fi
	old_version="$(cat "$DASHBOARD_DIR/dashboard.ver" 2>/dev/null)"
	if [ "$old_version" = "$version" ] && [ -s "$DASHBOARD_DIR/index.html" ]; then
		log "[dashboard] Current version: $version."
		return 0
	fi
	log "[dashboard] Local version: ${old_version:-NOT FOUND}, latest version: $version."
	if ! download "$(versioned_url "$DASHBOARD_SOURCE" "$version")" "$TMP_DIR/dashboard.zip"; then
		log "[dashboard] Update failed while downloading the dashboard."
		return 1
	fi
	if ! unzip -q "$TMP_DIR/dashboard.zip" -d "$TMP_DIR/dashboard"; then
		log "[dashboard] Update failed while extracting the dashboard."
		return 1
	fi
	for index in "$TMP_DIR/dashboard/index.html" "$TMP_DIR"/dashboard/*/index.html; do
		if [ -s "$index" ]; then
			source_dir="${index%/index.html}"
			break
		fi
	done
	if [ -z "$source_dir" ]; then
		log "[dashboard] Update failed: invalid dashboard archive."
		return 1
	fi
	if ! mkdir -p "$DASHBOARD_STAGE" ||
	   ! cp -a "$source_dir/." "$DASHBOARD_STAGE/" ||
	   ! rm -f "$DASHBOARD_STAGE/.etag" ||
	   ! printf '%s\n' "$version" > "$DASHBOARD_STAGE/dashboard.ver" ||
	   ! chmod -R a+rX "$DASHBOARD_STAGE"; then
		log "[dashboard] Update failed while staging the dashboard."
		return 1
	fi
	if ! mv "$DASHBOARD_DIR" "$backup_dir"; then
		log "[dashboard] Update failed while backing up the dashboard."
		return 1
	fi
	if ! mv "$DASHBOARD_STAGE" "$DASHBOARD_DIR"; then
		mv "$backup_dir" "$DASHBOARD_DIR" || log "[dashboard] Unable to restore the dashboard; backup retained at $backup_dir."
		log "[dashboard] Update failed: unable to replace dashboard files."
		return 1
	fi
	rm -rf "$backup_dir"
	mark_updated "dashboard"
	log "[dashboard] Successfully updated."
}

exec 9>"$RUN_DIR/update_resources.lock"
if ! flock -n 9 >/dev/null 2>&1; then
	log "[RESOURCES] A task is already running."
	exit 2
fi
rm -f "$RESULT_PATH"
log "[RESOURCES] Task started for provider '$RULESET_PROVIDER'."

TMP_DIR="$(mktemp -d "$RUN_DIR/resources-update.XXXXXX")" || {
	log "[RESOURCES] Failed to prepare the temporary update directory."
	finish 1
}
DASHBOARD_STAGE="${DASHBOARD_DIR}.new.$$"
trap 'rm -rf "$TMP_DIR" "$DASHBOARD_STAGE" "$RESOURCES_DIR/.update.$$.tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

update_rule_set "geoip_cn" "$GEOIP_SOURCE" "$GEOIP_VERSION_URL" || mark_failed "geoip_cn"
update_rule_set "geosite_cn" "$GEOSITE_SOURCE" "$GEOSITE_VERSION_URL" || mark_failed "geosite_cn"
update_dashboard || mark_failed "dashboard"

APPLY_FAILED=0
if [ "$CORE_UPDATED" = "1" ] || [ "$DASHBOARD_UPDATED" = "1" ]; then
	if /etc/init.d/homeproxy running >/dev/null 2>&1; then
		log "[RESOURCES] Applying updated resources and reloading service..."
		if ! /etc/init.d/homeproxy reload >/dev/null 2>&1; then
			log "[RESOURCES] Error: Failed to reload HomeProxy service."
			APPLY_FAILED=1
		else
			log "[RESOURCES] HomeProxy service reloaded successfully."
		fi
	fi
fi

if [ -n "$FAILED_BRANCHES" ]; then
	if [ -n "$UPDATED_BRANCHES" ]; then
		log "[RESOURCES] Partially updated ($UPDATED_BRANCHES); failed branches: $FAILED_BRANCHES."
		finish 4
	fi
	log "[RESOURCES] Update failed for: $FAILED_BRANCHES."
	finish 1
fi

if [ -z "$UPDATED_BRANCHES" ]; then
	log "[RESOURCES] You're already at the latest version."
	finish 3
fi

log "[RESOURCES] All resources updated successfully."
finish 0
