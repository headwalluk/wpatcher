#!/bin/bash

##
# wpatch.sh
#
# Version: 1.4.0
# Date: 2026-07-25
# Project URI: https://github.com/headwalluk/wpatcher
# Author: Paul Faulkner
# Author URI: https://headwall-hosting.com/
#
# Description
# A tool for patching and unpatching WordPress plugins and themes.
#
# IMPORTANT: This should only be used for making light changes to improve site
# performance or maintian security in abandoned plugins. It should not be used
# tp remove nullify plugins or themes. Example use cases are to remove
# excessive outgoing API calls, or to improve transient caching of slow result
# sets.
#
# See CHANGELOG.md for updates and changes.
# See README.md for usage and examples.
# See LICENSE for licensing information.
#
IS_VERBOSE=0
IS_RUNNING_FROM_REPOS=0
STARTUP_BIN=$(realpath "${0}")
STARTUP_DIR=$(realpath "$(dirname "${STARTUP_BIN}")")
IS_USING_CUSTOM_PATCHES_DIR=0

IS_FORCE_ENABLED=0

IS_THEMES_SUPPORT_ENABLAED=0

USE_MAINTENANCE_MODE=0

# Was -t/--type given explicitly? The "list" command shows every component type
# unless the caller asked for one, but REQUESTED_COMPONENT_TYPE always gets a
# default, so we can't tell the two apart without this.
IS_COMPONENT_TYPE_EXPLICIT=0

OUTPUT_FORMAT=table

GIT_REPOS=https://github.com/headwalluk/wpatcher.git

CONFIG_FILE_NAME=/etc/wpatcher.conf

WPCLI_PARAMS=

REQUIRED_VARIABLE_NAMES=(
  'STARTUP_DIR'
  'WORK_DIR'
  'PATCHES_DIR'
  'WP_ROOT'
  'REQUESTED_COMPONENT_TYPE'
  'REPOSITORY_DIR'
  'TEMP_DIR'
  'PATCHED_DIR'
  'COMMAND'
)

REQUIRED_BINARIES=('patch' 'tar' 'wp' 'tput' 'git')

COMPONENT_TYPES=('plugins' 'themes')

VALID_COMMANDS=('patch' 'unpatch' 'backup' 'update' 'dump' 'list')

VALID_OUTPUT_FORMATS=('table' 'csv' 'json')

# .	Colour
# 0	Black
# 1	Red
# 2	Green
# 3	Yellow
# 4	Blue
# 5	Magenta
# 6	Cyan
# 7	White
# 8	Not used
# 9	Reset to default color
COLOUR_ERROR=1
COLOUR_GOOD=2

# Extract the version from our headers.
STARTUP_VERSION=$(head -n 20 "${STARTUP_BIN}" | grep -E '[# ]+Version' | cut -d':' -f2 | xargs)
if [ -z "${STARTUP_VERSION}" ]; then
  echo "Failed to determine WPatcher version" >&2
  exit 1
fi

##
# Show usage
#
function show_usage_then_exit() {
  local BIN=$(basename "${0}")
  # echo "Usage: ${BIN} [-vh] [-p <WP_ROOT>] [-t <plugins|themes>] [-c <COMPONENT_SLUG>] <COMMAND>"
  echo "Usage: ${BIN} [-vhf] [-p <WP_ROOT>] [-d <PATCHES_DIR>] [-c <COMPONENT_SLUG>] <COMMAND>"
  echo

  echo "If WP_ROOT is not set, it's assumed WordPress is installed in the current directory."
  echo

  echo "Examples:"
  echo "   ${BIN} -p /var/www/example.com/htdocs patch"
  echo "   ${BIN} -p /var/www/example.com/htdocs backup"
  echo "   ${BIN} -p /var/www/example.com/htdocs --force -c woocommerce patch"
  echo "   ${BIN} -p /var/www/example.com/htdocs unpatch"
  echo "   ${BIN} -p /var/www/example.com/htdocs -c woocommerce unpatch"
  echo "   ${BIN} list                      (no site needed - reads the local repository)"
  echo "   ${BIN} list -c woocommerce"
  echo "   ${BIN} list --format=json"
  echo "   WP_ROOT=/home/me/htdocs ${BIN} patch"
  echo "   WP_ROOT=/home/me/htdocs ${BIN} -d ~/my-wp-pacthes/ patch"
  echo

  echo " Parameters:"
  echo "  -h --help             Show this page"
  echo "  -v --verbose          Show more output"
  echo "  -f --force            Force re-patching of an already-patched component"
  echo "  -m --maintenance      Switch the site into maintenance mode before patching"
  echo "  -p --path [WP_ROOT]   The htdocs root for the WordPress site"
  echo "  -d [PATCHES_DIR]      Custom location of the patches directory"
  echo "  -c --component [REQUESTED_COMPONENT_SLUG]   Patch/unpatch a single component"
  echo "  --format [OUTPUT_FORMAT]   Output format for 'list': $(echo ${VALID_OUTPUT_FORMATS[@]} | sed 's/ /|/g')"
  echo "  COMMAND               $(echo ${VALID_COMMANDS[@]} | sed 's/ /|/g')"
  echo

  exit 1
}

function show_inline_good() {
  local MESSAGE="${1}"
  echo -ne "$(tput setaf ${COLOUR_GOOD})${MESSAGE}$(tput sgr0)"
}

function show_inline_error() {
  local MESSAGE="${1}"
  echo -ne "$(tput setaf ${COLOUR_ERROR})${MESSAGE}$(tput sgr0)" >&2
}

##
# Show a banner/progress line. These go to stderr when we're emitting a
# machine-readable format, so stdout stays clean enough to pipe.
#
function show_banner_line() {
  local MESSAGE="${1}"

  if [ "${OUTPUT_FORMAT}" == 'table' ]; then
    echo "${MESSAGE}"
  else
    echo "${MESSAGE}" >&2
  fi
}

##
# Escape a string for embedding in a JSON document.
#
# Slugs and versions are already restricted to a JSON-safe character set before
# they reach here (see list_repository_components), so in practice this only
# matters for configured paths, which could in theory contain a quote.
#
function escape_json_string() {
  local VALUE="${1}"

  VALUE="${VALUE//\\/\\\\}"
  VALUE="${VALUE//\"/\\\"}"

  __="${VALUE}"
}

##
# Turn a byte count into something human-sized, without depending on numfmt.
#
function format_bytes_as_human() {
  local BYTES="${1}"
  local WHOLE=
  local TENTHS=

  if [ "${BYTES}" -ge 1073741824 ]; then
    WHOLE=$((BYTES / 1073741824))
    TENTHS=$(((BYTES % 1073741824) * 10 / 1073741824))
    __="${WHOLE}.${TENTHS}G"
  elif [ "${BYTES}" -ge 1048576 ]; then
    WHOLE=$((BYTES / 1048576))
    TENTHS=$(((BYTES % 1048576) * 10 / 1048576))
    __="${WHOLE}.${TENTHS}M"
  else
    __="$((BYTES / 1024))K"
  fi
}

##
# Configure and create directories
#
function configure_and_create_directories() {
  # Are we running from repository, or from installed location?
  if [ -d "${STARTUP_DIR}"/wpatches ]; then
    show_banner_line "Running from repository"

    # PATCHES_DIR might still need to be defined in /etc/wpatcher/conf so levae it empty for now.
    # PATCHES_DIR="${STARTUP_DIR}"/wpatches

    IS_RUNNING_FROM_REPOS=1
  fi

  if [ -z "${WORK_DIR}" ] && [ -n "${HOME}" ]; then
    WORK_DIR="${HOME}"/.wpatcher
  fi

  if [ -n "${WORK_DIR}" ] && [ ! -d "${WORK_DIR}" ]; then
    echo "Work directory does not exist: ${WORK_DIR}" >&2
    exit 1
  fi

  if [ -n "${WORK_DIR}" ]; then
    # Remove trailing slash. This assumes WORK_DIR is not simple "/"
    WORK_DIR="${WORK_DIR%/}"

    TEMP_DIR="${WORK_DIR}"/temp
    rm -fr "${TEMP_DIR}"
    mkdir -p "${TEMP_DIR}"

    REPOSITORY_DIR="${WORK_DIR}"/repos
    for COMPONENT_TYPE in "${COMPONENT_TYPES[@]}"; do
      mkdir -p "${REPOSITORY_DIR}"/"${COMPONENT_TYPE}"
    done

    PATCHED_DIR="${WORK_DIR}"/patched
    for COMPONENT_TYPE in "${COMPONENT_TYPES[@]}"; do
      mkdir -p "${PATCHED_DIR}"/"${COMPONENT_TYPE}"
    done

    if [ -z "${PATCHES_DIR}" ] && [ -d "${WORK_DIR}"/wpatches ]; then
      PATCHES_DIR="${WORK_DIR}"/wpatches
    fi
  fi

  # Normalise PATCHES_DIR the same way, whichever of the three sources it came
  # from. A trailing slash from the config file is harmless everywhere it's
  # used (each use appends its own "/"), but it made the reported paths
  # inconsistent with the WORK_DIR-derived ones, and with -d, which realpath
  # has already stripped. Same caveat as WORK_DIR above: assumes not "/".
  if [ -n "${PATCHES_DIR}" ]; then
    PATCHES_DIR="${PATCHES_DIR%/}"
  fi

  local REQUIRED_DIRS=("${REPOSITORY_DIR}" "${TEMP_DIR}" "${PATCHED_DIR}")
  for REQUIRED_DIR in "${REQUIRED_DIRS[@]}"; do
    if [ ! -d "${REQUIRED_DIR}" ]; then
      echo "Required directory does not exist: ${REQUIRED_DIR}" >&2
      exit 1
    elif [ ! -w "${REQUIRED_DIR}" ]; then
      echo "Required directory is not writable: ${REQUIRED_DIR}" >&2
      exit 1
    else
      # OK
      :
    fi
  done
}

##
# Check all required binaries are available
#
function fail_if_missing_required_binaries() {
  for REQUIRED_BINARY in "${REQUIRED_BINARIES[@]}"; do
    if ! command -v "${REQUIRED_BINARY}" &> /dev/null; then
      echo "Missing required binary: ${REQUIRED_BINARY}"
      exit 1
    fi
  done
}

##
# Check all required (global) variables have been set
#
function fail_if_missing_required_variables() {
  for REQUIRED_VARIABLE_NAME in "${REQUIRED_VARIABLE_NAMES[@]}"; do
    REQUIRED_VARIABLE_VALUE=${!REQUIRED_VARIABLE_NAME}
    if [ -z "${REQUIRED_VARIABLE_VALUE}" ]; then
      echo "Missing required variable: ${REQUIRED_VARIABLE_NAME}"
      show_usage_then_exit
    fi
  done
}

##
# Dump all required (global) variables
#
function dump_required_variables() {
  for REQUIRED_VARIABLE_NAME in "${REQUIRED_VARIABLE_NAMES[@]}"; do
    REQUIRED_VARIABLE_VALUE=${!REQUIRED_VARIABLE_NAME}
    show_banner_line "${REQUIRED_VARIABLE_NAME}: ${REQUIRED_VARIABLE_VALUE}"
  done
}

##
# Check a directory contains a valid WordPress installation.
# Fail if not.
#
function fail_if_bad_wp_root() {
  local WP_ROOT="${1}"
  if [ ! -f "${WP_ROOT}/wp-config.php" ]; then
    echo "Invalid WP_ROOT: ${WP_ROOT}"
    show_usage_then_exit
  fi

  wp ${WPCLI_PARAMS} --path="${WP_ROOT}" plugin list > /dev/null 2> /dev/null
  if [ $? -ne 0 ]; then
    echo "WordPress installation is not valid: ${WP_ROOT}"
    exit 1
  fi
}

##
# Get the site URL, and fail if it comes back empty.
#
function get_wp_site_url_but_fail_if_bad() {
  local WP_ROOT="${1}"
  local WP_URL=$(wp ${WPCLI_PARAMS} --path="${WP_ROOT}" --skip-plugins --skip-themes --skip-packages option get siteurl)

  if [ $? -ne 0 ] || [ -z "${WP_URL}" ]; then
    echo "Failed to get the WordPress website URL"
    exit 1
  fi

  __="${WP_URL}"
}

function get_component_wp_dir() {
  local WP_ROOT="${1}"
  local COMPONENT_TYPE="${2}"
  local COMPONENT_SLUG="${3}"

  __=${WP_ROOT}/wp-content/${COMPONENT_TYPE}/${COMPONENT_SLUG}
}

##
# Has a component already been patched within the WP site?
#
function has_component_been_patched() {
  local WP_ROOT="${1}"
  local COMPONENT_TYPE="${2}"
  local COMPONENT_SLUG="${3}"

  get_component_wp_dir "${WP_ROOT}" "${COMPONENT_TYPE}" "${COMPONENT_SLUG}"
  local COMPONENT_DIR="${__}"

  if [ -d "${COMPONENT_DIR}" ]; then
    pushd "${COMPONENT_DIR}" > /dev/null
    local FILE_NAMES=($(grep -lE '^// START : wpatcher' *.php 2> /dev/null))
    popd > /dev/null
  fi

  __=0
  if [ "${#FILE_NAMES[@]}" -gt 0 ]; then
    __=1
  fi
}

##
# Copy a component from the WP installation to our local repository.
#
function copy_component_to_repository() {
  local WP_ROOT="${1}"
  local COMPONENT_TYPE="${2}"
  local COMPONENT_SLUG="${3}"
  local COMPONENT_VERSION="${4}"

  echo -n "Copy unpatched ${COMPONENT_TYPE}/${COMPONENT_SLUG} (${COMPONENT_VERSION}) to local repos ... "

  tar -C "${WP_ROOT}"/wp-content/${COMPONENT_TYPE} \
    -czf "${REPOSITORY_DIR}"/${COMPONENT_TYPE}/${COMPONENT_SLUG},${COMPONENT_VERSION}.tgz "${COMPONENT_SLUG}"

  if [ $? -eq 0 ]; then
    echo $(show_inline_good "OK")
    __=1
  else
    echo $(show_inline_error "failed")
    __=0
  fi
}

##
# Create a local copy of the component, apply the patch and then
# create a tgz of the patched component.
#
function create_patched_component() {
  local COMPONENT_TYPE="${1}"
  local COMPONENT_SLUG="${2}"
  local COMPONENT_VERSION="${3}"
  local IS_PATCHED=0
  local IS_PACKAGED=0

  rm -fr "${TEMP_DIR}" && mkdir -p "${TEMP_DIR}"
  pushd "${TEMP_DIR}" > /dev/null

  echo -n "Extract and patch ${COMPONENT_TYPE}/${COMPONENT_SLUG} (${COMPONENT_VERSION}) ... "
  tar -xzf "${REPOSITORY_DIR}"/${COMPONENT_TYPE}/${COMPONENT_SLUG},${COMPONENT_VERSION}.tgz
  pushd "${COMPONENT_SLUG}" > /dev/null
  patch -p1 -i "${PATCHES_DIR}"/${COMPONENT_TYPE}/${COMPONENT_SLUG}/${COMPONENT_SLUG}-${COMPONENT_VERSION}.patch > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    IS_PATCHED=1
    echo $(show_inline_good "OK")
  else
    echo $(show_inline_error "failed")
  fi
  popd > /dev/null

  if [ ${IS_PATCHED} -eq 1 ]; then
    echo -n "Create patched package ${COMPONENT_TYPE}/${COMPONENT_SLUG} (${COMPONENT_VERSION}) ... "
    tar -czf "${PATCHED_DIR}"/${COMPONENT_TYPE}/${COMPONENT_SLUG},${COMPONENT_VERSION}.tgz "${COMPONENT_SLUG}"
    if [ $? -eq 0 ]; then
      IS_PACKAGED=1
      echo $(show_inline_good "OK")
    else
      echo $(show_inline_error "failed")
    fi
  fi
  popd > /dev/null

  __=${IS_PACKAGED}
}

function get_component_repository_package_file_name() {
  local COMPONENT_TYPE="${1}"
  local COMPONENT_SLUG="${2}"
  local COMPONENT_VERSION="${3}"

  # "patched" or "unpatched"
  local PACKAGE_TYPE="${4}"

  local FILE_NAME=

  if [ "${PACKAGE_TYPE}" == 'patched' ]; then
    FILE_NAME="${PATCHED_DIR}"/${COMPONENT_TYPE}/${COMPONENT_SLUG},${COMPONENT_VERSION}.tgz
  elif [ "${PACKAGE_TYPE}" == 'unpatched' ]; then
    FILE_NAME="${REPOSITORY_DIR}"/${COMPONENT_TYPE}/${COMPONENT_SLUG},${COMPONENT_VERSION}.tgz
  else
    :
  fi

  __="${FILE_NAME}"
}

##
# Do we already have a tgz of the patched component & version?
#
function does_patched_component_exist_in_repository() {
  local COMPONENT_TYPE="${1}"
  local COMPONENT_SLUG="${2}"
  local COMPONENT_VERSION="${3}"

  get_component_repository_package_file_name "${COMPONENT_TYPE}" "${COMPONENT_SLUG}" "${COMPONENT_VERSION}" 'patched'
  if [ -f "${__}" ]; then
    __=1
  else
    __=0
  fi
}

##
# Do we already have a tgz of the patched component & version?
#
function does_unpatched_component_exist_in_repository() {
  local COMPONENT_TYPE="${1}"
  local COMPONENT_SLUG="${2}"
  local COMPONENT_VERSION="${3}"

  get_component_repository_package_file_name "${COMPONENT_TYPE}" "${COMPONENT_SLUG}" "${COMPONENT_VERSION}" 'unpatched'
  if [ -f "${__}" ]; then
    __=1
  else
    __=0
  fi
}

##
# List the components held in the local repository.
#
# Read-only: this never touches a WordPress site, so it works without -p and
# without a valid WP installation. One row per slug+version, sorted by slug and
# then by natural version order (so 9.4.2 sorts before 10.9.4).
#
# PATCH = a .patch file exists for that exact version.
# BUILT = a patched package is already cached in PATCHED_DIR.
#
function list_repository_components() {
  local COMPONENT_TYPE=
  local COMPONENT_SLUG=
  local COMPONENT_VERSION=
  local PACKAGE_NAME=
  local PACKAGE_NAMES=()
  local WANTED_NAMES=()
  local PACKAGE_FILE_NAMES=()
  local PACKAGE_SIZES=()
  local PACKAGE_BYTES=0
  local PACKAGE_INDEX=0
  local PATCH_FILE_NAME=
  local HAS_PATCH=
  local HAS_BUILD=
  local ROWS=()
  local JSON_ROWS=()
  local JSON_INDEX=0
  local JSON_SUFFIX=
  local ROW=
  local ROW_TYPE=
  local ROW_SLUG=
  local ROW_VERSION=
  local ROW_SIZE=
  local ROW_PATCH=
  local ROW_BUILT=
  local SLUGS_SEEN=()
  local UNIQUE_SLUG_COUNT=0
  local WIDEST_SLUG=4
  local WIDEST_VERSION=7
  local TOTAL_COUNT=0
  local TOTAL_BYTES=0
  local TOTAL_HUMAN=

  if [ ! -d "${PATCHES_DIR}" ]; then
    echo "Warning: patches directory not found, so PATCH will read 'no' for everything: ${PATCHES_DIR}" >&2
  fi

  if [ "${OUTPUT_FORMAT}" == 'csv' ]; then
    echo 'type,slug,version,bytes,patch,built'
  fi

  for COMPONENT_TYPE in "${COMPONENT_TYPES[@]}"; do
    # Only filter by type if the caller actually asked for one.
    if [ ${IS_COMPONENT_TYPE_EXPLICIT} -eq 1 ] && [ "${REQUESTED_COMPONENT_TYPE}" != "${COMPONENT_TYPE}" ]; then
      continue
    fi

    # readarray, not $(...) in an array literal: a package name containing a
    # space would otherwise word-split into two bogus entries.
    readarray -t PACKAGE_NAMES < <(ls -1 "${REPOSITORY_DIR}"/"${COMPONENT_TYPE}"/*.tgz 2> /dev/null | sed 's|.*/||; s|\.tgz$||' | sort -t',' -k1,1 -k2,2V)

    if [ "${#PACKAGE_NAMES[@]}" -eq 0 ]; then
      continue
    fi

    # Validate and filter BEFORE stat'ing. Packages are named
    # "<slug>,<version>.tgz", and both parts come from WordPress so they're
    # always plain. Anything else isn't a package we wrote - rejecting it here
    # keeps every field safe to drop into CSV or JSON unquoted, and means the
    # stat call below can't fail and desync from the list it's sized against.
    WANTED_NAMES=()
    for PACKAGE_NAME in "${PACKAGE_NAMES[@]}"; do
      if [[ ! "${PACKAGE_NAME}" =~ ^[A-Za-z0-9._-]+,[A-Za-z0-9._-]+$ ]]; then
        if [[ "${PACKAGE_NAME}" == *,* ]]; then
          # Looks like a package but isn't one we can trust - always say so,
          # otherwise it silently vanishes from the counts.
          echo "Skipping package with unexpected characters in its name: ${PACKAGE_NAME}.tgz" >&2
        elif [ ${IS_VERBOSE} -ne 0 ]; then
          echo "Ignoring unrecognised package name: ${PACKAGE_NAME}.tgz" >&2
        fi

        continue
      fi

      if [ -n "${REQUESTED_COMPONENT_SLUG}" ] && [ "${REQUESTED_COMPONENT_SLUG}" != "${PACKAGE_NAME%%,*}" ]; then
        continue
      fi

      WANTED_NAMES+=("${PACKAGE_NAME}")
    done

    if [ "${#WANTED_NAMES[@]}" -eq 0 ]; then
      continue
    fi

    # Take all the sizes in one stat call rather than one per package.
    PACKAGE_FILE_NAMES=()
    for PACKAGE_NAME in "${WANTED_NAMES[@]}"; do
      PACKAGE_FILE_NAMES+=("${REPOSITORY_DIR}/${COMPONENT_TYPE}/${PACKAGE_NAME}.tgz")
    done
    readarray -t PACKAGE_SIZES < <(stat --printf '%s\n' "${PACKAGE_FILE_NAMES[@]}" 2> /dev/null)

    # Belt and braces: if a package disappeared between the listing and the
    # stat, bail rather than report every size against the wrong package.
    if [ "${#PACKAGE_SIZES[@]}" -ne "${#WANTED_NAMES[@]}" ]; then
      echo "Failed to read package sizes in ${REPOSITORY_DIR}/${COMPONENT_TYPE} - did the repository change while listing?" >&2
      return 1
    fi

    for ((PACKAGE_INDEX = 0; PACKAGE_INDEX < ${#WANTED_NAMES[@]}; PACKAGE_INDEX++)); do
      PACKAGE_NAME="${WANTED_NAMES[${PACKAGE_INDEX}]}"

      COMPONENT_SLUG="${PACKAGE_NAME%%,*}"
      COMPONENT_VERSION="${PACKAGE_NAME#*,}"
      PACKAGE_BYTES="${PACKAGE_SIZES[${PACKAGE_INDEX}]}"

      PATCH_FILE_NAME="${PATCHES_DIR}"/${COMPONENT_TYPE}/${COMPONENT_SLUG}/${COMPONENT_SLUG}-${COMPONENT_VERSION}.patch
      if [ -f "${PATCH_FILE_NAME}" ]; then
        HAS_PATCH=1
      else
        HAS_PATCH=0
      fi

      does_patched_component_exist_in_repository "${COMPONENT_TYPE}" "${COMPONENT_SLUG}" "${COMPONENT_VERSION}"
      HAS_BUILD=${__}

      TOTAL_COUNT=$((TOTAL_COUNT + 1))
      TOTAL_BYTES=$((TOTAL_BYTES + PACKAGE_BYTES))
      SLUGS_SEEN+=("${COMPONENT_SLUG}")

      if [ "${OUTPUT_FORMAT}" == 'csv' ]; then
        echo "${COMPONENT_TYPE},${COMPONENT_SLUG},${COMPONENT_VERSION},${PACKAGE_BYTES},${HAS_PATCH},${HAS_BUILD}"
      elif [ "${OUTPUT_FORMAT}" == 'json' ]; then
        [ ${HAS_PATCH} -eq 1 ] && ROW_PATCH=true || ROW_PATCH=false
        [ ${HAS_BUILD} -eq 1 ] && ROW_BUILT=true || ROW_BUILT=false

        JSON_ROWS+=("    { \"type\": \"${COMPONENT_TYPE}\", \"slug\": \"${COMPONENT_SLUG}\", \"version\": \"${COMPONENT_VERSION}\", \"bytes\": ${PACKAGE_BYTES}, \"patch\": ${ROW_PATCH}, \"built\": ${ROW_BUILT} }")
      else
        # Buffer the rows so we can size the slug column to the widest one.
        [ "${#COMPONENT_SLUG}" -gt ${WIDEST_SLUG} ] && WIDEST_SLUG="${#COMPONENT_SLUG}"
        [ "${#COMPONENT_VERSION}" -gt ${WIDEST_VERSION} ] && WIDEST_VERSION="${#COMPONENT_VERSION}"

        format_bytes_as_human "${PACKAGE_BYTES}"

        [ ${HAS_PATCH} -eq 1 ] && ROW_PATCH=yes || ROW_PATCH=no
        [ ${HAS_BUILD} -eq 1 ] && ROW_BUILT=yes || ROW_BUILT=no

        ROWS+=("${COMPONENT_TYPE}"$'\t'"${COMPONENT_SLUG}"$'\t'"${COMPONENT_VERSION}"$'\t'"${__}"$'\t'"${ROW_PATCH}"$'\t'"${ROW_BUILT}")
      fi
    done
  done

  if [ ${TOTAL_COUNT} -gt 0 ]; then
    UNIQUE_SLUG_COUNT=$(printf '%s\n' "${SLUGS_SEEN[@]}" | sort -u | wc -l)
  fi

  # JSON always emits a complete, parseable document - including when there's
  # nothing to report - so callers can pipe it straight into jq unconditionally.
  if [ "${OUTPUT_FORMAT}" == 'json' ]; then
    escape_json_string "${REPOSITORY_DIR}"
    local JSON_REPOSITORY_DIR="${__}"
    escape_json_string "${PATCHES_DIR}"
    local JSON_PATCHES_DIR="${__}"

    echo '{'
    echo "  \"wpatcher_version\": \"${STARTUP_VERSION}\","
    echo "  \"repository_dir\": \"${JSON_REPOSITORY_DIR}\","
    echo "  \"patches_dir\": \"${JSON_PATCHES_DIR}\","
    echo "  \"totals\": { \"backups\": ${TOTAL_COUNT}, \"slugs\": ${UNIQUE_SLUG_COUNT}, \"bytes\": ${TOTAL_BYTES} },"

    if [ "${#JSON_ROWS[@]}" -eq 0 ]; then
      echo '  "components": []'
    else
      echo '  "components": ['
      for ((JSON_INDEX = 0; JSON_INDEX < ${#JSON_ROWS[@]}; JSON_INDEX++)); do
        # No trailing comma on the last element.
        if [ ${JSON_INDEX} -eq $((${#JSON_ROWS[@]} - 1)) ]; then
          JSON_SUFFIX=
        else
          JSON_SUFFIX=','
        fi
        echo "${JSON_ROWS[${JSON_INDEX}]}${JSON_SUFFIX}"
      done
      echo '  ]'
    fi

    echo '}'
  fi

  if [ ${TOTAL_COUNT} -eq 0 ]; then
    if [ -n "${REQUESTED_COMPONENT_SLUG}" ]; then
      echo "Nothing in the local repository for component: ${REQUESTED_COMPONENT_SLUG}" >&2
      return 1
    fi

    [ "${OUTPUT_FORMAT}" == 'table' ] && show_banner_line "The local repository is empty: ${REPOSITORY_DIR}"
    return 0
  fi

  if [ "${OUTPUT_FORMAT}" == 'table' ]; then
    printf '%-8s %-*s  %-*s %8s  %-5s  %s\n' \
      'TYPE' ${WIDEST_SLUG} 'SLUG' ${WIDEST_VERSION} 'VERSION' 'SIZE' 'PATCH' 'BUILT'

    for ROW in "${ROWS[@]}"; do
      IFS=$'\t' read -r ROW_TYPE ROW_SLUG ROW_VERSION ROW_SIZE ROW_PATCH ROW_BUILT <<< "${ROW}"
      printf '%-8s %-*s  %-*s %8s  %-5s  %s\n' \
        "${ROW_TYPE}" ${WIDEST_SLUG} "${ROW_SLUG}" ${WIDEST_VERSION} "${ROW_VERSION}" "${ROW_SIZE}" "${ROW_PATCH}" "${ROW_BUILT}"
    done

    format_bytes_as_human "${TOTAL_BYTES}"
    TOTAL_HUMAN="${__}"

    echo
    echo "${TOTAL_COUNT} backup$([ ${TOTAL_COUNT} -ne 1 ] && echo s), ${UNIQUE_SLUG_COUNT} slug$([ ${UNIQUE_SLUG_COUNT} -ne 1 ] && echo s), ${TOTAL_HUMAN}"
  fi

  return 0
}

##
# Deploy either a patched or unpatched component to a WP site. If the component
# already exists in the WP site, make a temp backup of it so we can revert this
# deployment if something goes wrong.
#
function deploy_component_to_site() {
  local WP_ROOT="${1}"
  local COMPONENT_TYPE="${2}"
  local COMPONENT_SLUG="${3}"
  local COMPONENT_VERSION="${4}"

  ## "patch" or "unpatch"
  local ACTION="${5}"

  local IS_NEW_COMPONENT_EXTRACTED=0
  local IS_NEW_COMPONENT_INSTALLED=0

  local TARGET_BASE_DIR="${WP_ROOT}"/wp-content/${COMPONENT_TYPE}
  local COMPONENT_SOURCE_PACKAGE=
  local COMPONENT_TARGET_DIR="${TARGET_BASE_DIR}"/"${COMPONENT_SLUG}"
  local COMPONENT_BACKUP_DIR="${TARGET_BASE_DIR}"/"${COMPONENT_SLUG}"-temp

  __=
  if [ "${ACTION}" == 'patch' ]; then
    get_component_repository_package_file_name "${COMPONENT_TYPE}" "${COMPONENT_SLUG}" "${COMPONENT_VERSION}" 'patched'
    COMPONENT_SOURCE_PACKAGE="${__}"
  elif [ "${ACTION}" == 'unpatch' ]; then
    get_component_repository_package_file_name "${COMPONENT_TYPE}" "${COMPONENT_SLUG}" "${COMPONENT_VERSION}" 'unpatched'
    COMPONENT_SOURCE_PACKAGE="${__}"
  else
    :
  fi

  if [ -z "${__}" ] || [ ! -f "${COMPONENT_SOURCE_PACKAGE}" ]; then
    echo "Unable to ${ACTION} component: ${COMPONENT_TYPE}/${COMPONENT_SLUG} (${COMPONENT_VERSION}) - missing from repository"
  else
    # Extract the unpatched component to a temp directory.
    rm -r "${TEMP_DIR}" && mkdir -p "${TEMP_DIR}"
    if [ $? -eq 0 ]; then
      pushd "${TEMP_DIR}" > /dev/null

      echo -n "Extracting ${ACTION} ${COMPONENT_TYPE}/${COMPONENT_SLUG} (${COMPONENT_VERSION}) ... "
      tar -xzf "${COMPONENT_SOURCE_PACKAGE}"
      if [ $? -eq 0 ] && [ -d "${TEMP_DIR}"/"${COMPONENT_SLUG}" ]; then
        IS_NEW_COMPONENT_EXTRACTED=1
        echo $(show_inline_good "OK")
      else
        echo $(show_inline_error "failed")
      fi

      popd > /dev/null
    fi

    # If the component is already installed on the WP site, back it up.
    rm -fr "${COMPONENT_BACKUP_DIR}"
    if [ -d "${COMPONENT_TARGET_DIR}" ]; then
      echo -n "Temp Backup ${COMPONENT_TYPE}/${COMPONENT_SLUG} (${COMPONENT_VERSION}) ... "
      mv "${COMPONENT_TARGET_DIR}" "${COMPONENT_BACKUP_DIR}"
      if [ $? -eq 0 ] && [ -d "${COMPONENT_BACKUP_DIR}" ]; then
        echo $(show_inline_good "OK")
      else
        echo $(show_inline_error "failed")
      fi
    fi

    if [ ! -d "${COMPONENT_TARGET_DIR}" ] && [ ${IS_NEW_COMPONENT_EXTRACTED} -eq 1 ]; then
      echo -n "Deploy ${ACTION} ${COMPONENT_TYPE}/${COMPONENT_SLUG} (${COMPONENT_VERSION}) ... "
      mv "${TEMP_DIR}"/"${COMPONENT_SLUG}" "${COMPONENT_TARGET_DIR}"
      if [ $? -eq 0 ] && [ -d "${COMPONENT_TARGET_DIR}" ]; then
        IS_NEW_COMPONENT_INSTALLED=1
        echo $(show_inline_good "OK")
      else
        echo $(show_inline_error "failed")
      fi
    fi

    if [ ${IS_NEW_COMPONENT_INSTALLED} -ne 1 ] && [ -d "${COMPONENT_BACKUP_DIR}" ]; then
      echo "Restoring backed-up ${COMPONENT_TYPE}/${COMPONENT_SLUG} (${COMPONENT_VERSION})"
      mv "${COMPONENT_BACKUP_DIR}" "${COMPONENT_TARGET_DIR}"
    fi

  fi

  if [ ${IS_NEW_COMPONENT_INSTALLED} -eq 1 ] && [ -d "${COMPONENT_BACKUP_DIR}" ]; then
    rm -fr "${COMPONENT_BACKUP_DIR}"
  fi

  __=${IS_NEW_COMPONENT_INSTALLED}
}

##
# Deploy a patched component to a WP site.
#
function apply_patch() {
  local WP_ROOT="${1}"
  local PATCH_META="${2}"

  local COMPONENT_TYPE=$(echo "${PATCH_META}" | cut -d',' -f1)
  local COMPONENT_SLUG=$(echo "${PATCH_META}" | cut -d',' -f2)
  local COMPONENT_VERSION=$(echo "${PATCH_META}" | cut -d',' -f3)
  local PATCH_FILE_NAME=$(echo "${PATCH_META}" | cut -d',' -f4)

  local DOES_UNPATCHED_COMPONENT_EXIST_IN_REPOS=0
  local DOES_PATCHED_COMPONENT_EXIST_IN_REPOS=0
  local PATCHED_COMPONENT_FILE_NAME=

  has_component_been_patched "${WP_ROOT}" "${COMPONENT_TYPE}" "${COMPONENT_SLUG}"
  if [ ${__} -ne 1 ]; then
    does_unpatched_component_exist_in_repository "${COMPONENT_TYPE}" "${COMPONENT_SLUG}" "${COMPONENT_VERSION}"
    if [ ${__} -ne 1 ]; then
      copy_component_to_repository "${WP_ROOT}" "${COMPONENT_TYPE}" "${COMPONENT_SLUG}" "${COMPONENT_VERSION}"
    fi
  fi

  does_unpatched_component_exist_in_repository "${COMPONENT_TYPE}" "${COMPONENT_SLUG}" "${COMPONENT_VERSION}"
  DOES_UNPATCHED_COMPONENT_EXIST_IN_REPOS=${__}

  # If a patched component already exists, but the patch diff file is newer,
  # delete the patched component now.
  get_component_repository_package_file_name "${COMPONENT_TYPE}" "${COMPONENT_SLUG}" "${COMPONENT_VERSION}" 'patched'
  PATCHED_COMPONENT_FILE_NAME="${__}"
  if [ -z "${PATCHED_COMPONENT_FILE_NAME}" ] || [ ! "${PATCHED_COMPONENT_FILE_NAME}" ]; then
    :
  elif [ "${PATCHED_COMPONENT_FILE_NAME}" -nt "${PATCH_FILE_NAME}" ]; then
    :
  else
    echo "Delete old patched component ${PATCHED_COMPONENT_FILE_NAME}"
    rm -f "${PATCHED_COMPONENT_FILE_NAME}"
  fi

  does_patched_component_exist_in_repository "${COMPONENT_TYPE}" "${COMPONENT_SLUG}" "${COMPONENT_VERSION}"
  DOES_PATCHED_COMPONENT_EXIST_IN_REPOS=${__}

  if [ ${DOES_PATCHED_COMPONENT_EXIST_IN_REPOS} -ne 1 ] && [ ${DOES_UNPATCHED_COMPONENT_EXIST_IN_REPOS} -eq 1 ]; then
    create_patched_component "${COMPONENT_TYPE}" "${COMPONENT_SLUG}" "${COMPONENT_VERSION}"
  fi

  does_patched_component_exist_in_repository "${COMPONENT_TYPE}" "${COMPONENT_SLUG}" "${COMPONENT_VERSION}"
  if [ ${__} -eq 1 ]; then
    deploy_component_to_site "${WP_ROOT}" "${COMPONENT_TYPE}" "${COMPONENT_SLUG}" "${COMPONENT_VERSION}" 'patch'
  fi

  # This sets __ to 1 if the component was successfully patched.
  has_component_been_patched "${WP_ROOT}" "${COMPONENT_TYPE}" "${COMPONENT_SLUG}"
}

##
# If a site is running a patched component, and the unpatched version of that
# component is in our local repository, deploy the unpatched component to the
# site.
#
function revert_patch() {
  local WP_ROOT="${1}"
  local PATCH_META="${2}"

  local COMPONENT_TYPE=$(echo "${PATCH_META}" | cut -d',' -f1)
  local COMPONENT_SLUG=$(echo "${PATCH_META}" | cut -d',' -f2)
  local COMPONENT_VERSION=$(echo "${PATCH_META}" | cut -d',' -f3)
  local PATCH_FILE_NAME=$(echo "${PATCH_META}" | cut -d',' -f4)

  has_component_been_patched "${WP_ROOT}" "${COMPONENT_TYPE}" "${COMPONENT_SLUG}"
  local HAS_PATCH_BEEN_APPLIED=${__}

  does_unpatched_component_exist_in_repository "${COMPONENT_TYPE}" "${COMPONENT_SLUG}" "${COMPONENT_VERSION}"
  local DOES_UNPATCHED_COMPONENT_EXIST_IN_REPOS=${__}

  if [ ${HAS_PATCH_BEEN_APPLIED} -ne 1 ]; then
    # A patched version of the component is not installed on the WP site.
    :
  elif [ ${DOES_UNPATCHED_COMPONENT_EXIST_IN_REPOS} -ne 1 ]; then
    # The unpatched version of this component does not exist in our local repository.
    :
    get_component_repository_package_file_name "${COMPONENT_TYPE}" "${COMPONENT_SLUG}" "${COMPONENT_VERSION}" 'unpatched'
  else
    deploy_component_to_site "${WP_ROOT}" "${COMPONENT_TYPE}" "${COMPONENT_SLUG}" "${COMPONENT_VERSION}" 'unpatch'
  fi
}

function update_from_upstream() {
  rm -fr "${TEMP_DIR}" && mkdir -p "${TEMP_DIR}"

  pushd "${TEMP_DIR}" > /dev/null

  git clone "${GIT_REPOS}"
  if [ $? -ne 0 ]; then
    echo "Failed to clone upstream repository"
  else
    if [ ${IS_USING_CUSTOM_PATCHES_DIR} -eq 0 ]; then
      echo -n "Updating latest patches ... "
      rm -fr "${PATCHES_DIR}" && cp -r wpatcher/wpatches "${PATCHES_DIR}"
      if [ $? -eq 0 ]; then
        echo $(show_inline_good "OK")
      else
        echo $(show_inline_error "failed")
      fi
    fi

    if [ ${IS_RUNNING_FROM_REPOS} -ne 1 ] && [ -w "${STARTUP_BIN}" ]; then
      echo -n "Updating $(basename "${STARTUP_BIN}") ... "
      cp wpatcher/wpatch.sh "${STARTUP_BIN}"
      if [ $? -eq 0 ]; then
        echo $(show_inline_good "OK")
      else
        echo $(show_inline_error "failed")
      fi
    fi
  fi

  popd > /dev/null

  echo END
  exit 0

  for COMPONENT_TYPE in "${COMPONENT_TYPES[@]}"; do
    mkdir -p "${PATCHES_DIR}"/"${COMPONENT_TYPE}"
  done

  rm -fr "${TEMP_DIR}"
}

##
# Load system configuration
#
function load_configuration() {
  if [ -n "${CONFIG_FILE_NAME}" ] && [ -f "${CONFIG_FILE_NAME}" ]; then
    [ ${IS_VERBOSE} -ne 0 ] && echo "Loading configuration from ${CONFIG_FILE_NAME}"

    source "${CONFIG_FILE_NAME}"

    if [ -n "${PATCHES_DIR}" ]; then
      IS_USING_CUSTOM_PATCHES_DIR=1
    fi
  fi
}

##
# parse command-line arguments
#
function parse_command_line() {
  while true; do
    case "${1}" in
      -h | --help)
        show_usage_then_exit
        ;;

      -v | --verbose)
        IS_VERBOSE=1
        shift
        ;;

      -f | --force)
        IS_FORCE_ENABLED=1
        shift
        ;;

      -p | --path)
        WP_ROOT="${2}"
        shift 2
        ;;

      -m | --maintenance)
        USE_MAINTENANCE_MODE=1
        shift
        ;;

      -d)
        PATCHES_DIR="$(realpath "${2}")"
        IS_USING_CUSTOM_PATCHES_DIR=1
        shift 2
        ;;

      -t | --type)
        REQUESTED_COMPONENT_TYPE="${2}"
        IS_COMPONENT_TYPE_EXPLICIT=1
        shift 2
        ;;

      --format)
        OUTPUT_FORMAT="${2}"
        shift 2
        ;;

      --format=*)
        OUTPUT_FORMAT="${1#*=}"
        shift
        ;;

      -c | --component)
        REQUESTED_COMPONENT_SLUG="${2}"
        shift 2
        ;;

      # --)
      #   shift
      #   break
      #   ;;

      *)
        if [ -n "${1}" ] && [ -z "${COMMAND}" ]; then
          COMMAND="${1}"
          shift
        elif [ -n "${1}" ] && [ -n "${COMMAND}" ]; then
          echo "Cannot have multiple commands" >&2
          show_usage_then_exit
        else
          # Finished parsing the command line
          break
        fi
        ;;

    esac
  done

  if [ -z "${WP_ROOT}" ]; then
    WP_ROOT="$(realpath "${PWD}")"
  fi

  if [ -z "${REQUESTED_COMPONENT_TYPE}" ]; then
    REQUESTED_COMPONENT_TYPE="${COMPONENT_TYPES[0]}"
  fi

  if [ -z "${COMMAND}" ]; then
    echo "COMMAND not specified" >&2
    show_usage_then_exit
  elif [[ ! " ${VALID_COMMANDS[*]} " =~ [[:space:]]"${COMMAND}"[[:space:]] ]]; then
    echo "COMMAND invalid: ${COMMAND}" >&2
    show_usage_then_exit
  else
    :
  fi

  if [[ ! " ${VALID_OUTPUT_FORMATS[*]} " =~ [[:space:]]"${OUTPUT_FORMAT}"[[:space:]] ]]; then
    echo "OUTPUT_FORMAT invalid: ${OUTPUT_FORMAT}" >&2
    show_usage_then_exit
  fi

  if [ "${COMMAND}" == 'dump' ]; then
    IS_VERBOSE=1
  fi
}

# if [ -z "${COMMAND}" ]; then
#   COMMAND='patch'
# fi

load_configuration

parse_command_line "${@}"

# Deferred until the command line is parsed, so we know whether stdout has to
# stay clean for a machine-readable format.
show_banner_line "WPatcher :: ${STARTUP_VERSION} :: ${GIT_REPOS}"

fail_if_missing_required_binaries

configure_and_create_directories

fail_if_missing_required_variables

if [ "${COMMAND}" != 'list' ] && [ "${REQUESTED_COMPONENT_TYPE}" == 'themes' ] && [ ${IS_THEMES_SUPPORT_ENABLAED} -ne 1 ]; then
  echo "Themes support is not implemented yet" >&2
  exit 1
fi

if [ ${IS_VERBOSE} -ne 0 ]; then
  dump_required_variables
  # exit 0
fi

if [ "${COMMAND}" == 'update' ]; then
  update_from_upstream
  exit 0
fi

# "list" only reads the local repository, so it must run before everything
# below here, which all assumes a valid site and an installed patch collection.
if [ "${COMMAND}" == 'list' ]; then
  list_repository_components
  exit ${?}
fi

if [ ! -d "${PATCHES_DIR}" ]; then
  echo "No patches installed in ${PATCHES_DIR}" >&2
  echo "To update patches from upstream: ${0} update" >&2

  exit 1
fi

if [ ${EUID} -eq 0 ]; then
  WPCLI_PARAMS=--allow-root
fi

fail_if_bad_wp_root "${WP_ROOT}"

get_wp_site_url_but_fail_if_bad "${WP_ROOT}"
WP_URL="${__}"

echo "Site: ${WP_URL}"

if [ "${COMMAND}" == 'abort' ]; then
  show_inline_error "ABORT"
  echo
  exit 1
fi

##
# Get a list of active plugins & themes on the site.
#
ACTIVE_PLUGINS=($(wp ${WPCLI_PARAMS} plugin list --path="${WP_ROOT}" --skip-plugins --skip-themes --skip-packages --status=active --skip-update-check --format=csv --fields=name,version | grep -vE '^name,'))
ACTIVE_THEMES=($(wp ${WPCLI_PARAMS} theme list --path="${WP_ROOT}" --skip-plugins --skip-themes --skip-packages --status=active,parent --skip-update-check --format=csv --fields=name,version | grep -vE '^name,'))

ACTIVE_COMPONENTS=($(printf 'plugins,%s\n' "${ACTIVE_PLUGINS[@]}") $(printf 'themes,%s\n' "${ACTIVE_THEMES[@]}"))

##
# Create a list of plugins/themes that have patches available and create a patch-list.
# Each record in the patch-list is a comma-separated string:
#
#   COMPONENT_TYPE,COMPONENT_SLUG,COMPONENT_VERSION,PATCH_FILE_NAME
#
echo "Scanning site for components to ${COMMAND}"
PATCH_LIST=()
for COMPONENT_META in "${ACTIVE_COMPONENTS[@]}"; do
  COMPONENT_TYPE=$(echo "${COMPONENT_META}" | cut -d',' -f1)
  COMPONENT_SLUG=$(echo "${COMPONENT_META}" | cut -d',' -f2)
  COMPONENT_VERSION=$(echo "${COMPONENT_META}" | cut -d',' -f3)
  PATCH_FILE_NAME=${PATCHES_DIR}/${COMPONENT_TYPE}/${COMPONENT_SLUG}/${COMPONENT_SLUG}-${COMPONENT_VERSION}.patch
  IS_WANTED=0
  HAS_BEEN_PATCHED=0

  if [ "${REQUESTED_COMPONENT_TYPE}" != "${COMPONENT_TYPE}" ]; then
    :
  elif [ -n "${REQUESTED_COMPONENT_SLUG}" ] && [ "${REQUESTED_COMPONENT_SLUG}" != "${COMPONENT_SLUG}" ]; then
    :
  else
    [ ${IS_VERBOSE} -ne 0 ] && echo -n "PATCH: ${PATCH_FILE_NAME} ... "

    if [ -f "${PATCH_FILE_NAME}" ]; then
      has_component_been_patched "${WP_ROOT}" "${COMPONENT_TYPE}" "${COMPONENT_SLUG}"
      HAS_BEEN_PATCHED=${__}
    fi

    if [ "${COMMAND}" == 'backup' ] && [ ${HAS_BEEN_PATCHED} -ne 1 ]; then
      IS_WANTED=1
    elif [ "${COMMAND}" == 'unpatch' ] && [ -f "${PATCH_FILE_NAME}" ] && [ ${HAS_BEEN_PATCHED} -eq 1 ]; then
      IS_WANTED=1
    elif [ "${COMMAND}" == 'patch' ] && [ -f "${PATCH_FILE_NAME}" ] && { [ ${HAS_BEEN_PATCHED} -eq 0 ] || [ ${IS_FORCE_ENABLED} -eq 1 ]; }; then
      IS_WANTED=1
    else
      :
    fi

    if [ ${IS_WANTED} -eq 1 ]; then
      [ ${IS_VERBOSE} -ne 0 ] && echo "${COMMAND}"
      PATCH_LIST+=("${COMPONENT_TYPE},${COMPONENT_SLUG},${COMPONENT_VERSION},${PATCH_FILE_NAME}")
    else
      [ ${IS_VERBOSE} -ne 0 ] && echo "skip"
    fi
  fi
done

if [ "${#PATCH_LIST[@]}" -eq 0 ]; then
  echo "There are no components to ${COMMAND}"
  exit 0
fi

if [ ${IS_VERBOSE} -eq 1 ]; then
  echo "${COMMAND} list"
  printf ' >>> %s\n' "${PATCH_LIST[@]}"
  echo
fi

##
# Ready to apply the patch list.
#
IS_IN_MAINTENANCE_MODE=0
if [ ${USE_MAINTENANCE_MODE} -ne 0 ]; then
  # TODO: Fail if the site is already in maintenance mode?

  [ -w "${WP_ROOT}" ] && wp ${WPCLI_PARAMS} --path="${WP_ROOT}" --skip-plugins --skip-themes --skip-packages maintenance-mode activate

  IS_IN_MAINTENANCE_MODE=1

  # TODO: Check we are actually in mainteancne mode
fi

PATCH_INDEX=0
for PATCH_META in "${PATCH_LIST[@]}"; do
  COMPONENT_TYPE=$(echo "${PATCH_META}" | cut -d',' -f1)
  COMPONENT_SLUG=$(echo "${PATCH_META}" | cut -d',' -f2)
  COMPONENT_VERSION=$(echo "${PATCH_META}" | cut -d',' -f3)
  PATCH_FILE_NAME=$(echo "${PATCH_META}" | cut -d',' -f4)

  if [ "${COMMAND}" == 'backup' ]; then
    # Only backup unpatched components to the repository.
    has_component_been_patched "${WP_ROOT}" "${COMPONENT_TYPE}" "${COMPONENT_SLUG}"
    HAS_BEEN_PATCHED=${__}

    does_unpatched_component_exist_in_repository "${COMPONENT_TYPE}" "${COMPONENT_SLUG}" "${COMPONENT_VERSION}"
    EXISTS_IN_LOCAL=${__}

    if [ ${HAS_BEEN_PATCHED} -ne 1 ] && [ ${EXISTS_IN_LOCAL} -ne 1 ]; then
      copy_component_to_repository "${WP_ROOT}" "${COMPONENT_TYPE}" "${COMPONENT_SLUG}" "${COMPONENT_VERSION}"
      EXISTS_IN_LOCAL=${__}
    fi
  elif [ "${COMMAND}" == 'patch' ]; then
    apply_patch "${WP_ROOT}" "${PATCH_META}"
    echo
  elif [ "${COMMAND}" == 'unpatch' ]; then
    revert_patch "${WP_ROOT}" "${PATCH_META}"
    echo
  else
    # Unknown command
    :
  fi

  PATCH_INDEX=$((PATCH_INDEX + 1))
done

if [ ${USE_MAINTENANCE_MODE} -ne 0 ] && [ ${IS_IN_MAINTENANCE_MODE} -eq 1 ]; then
  [ -w "${WP_ROOT}" ] && wp ${WPCLI_PARAMS} --path="${WP_ROOT}" --skip-plugins --skip-themes --skip-packages maintenance-mode deactivate
fi

echo "Finished"
exit 0
