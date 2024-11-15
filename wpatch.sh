#!/bin/bash

##
# wpatch.sh
#
# Version: 1.3.0
# Date: 2024-11-13
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

VALID_COMMANDS=('patch' 'unpatch' 'backup' 'update' 'dump')

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
# Configure and create directories
#
function configure_and_create_directories() {
  # Are we running from repository, or from installed location?
  if [ -d "${STARTUP_DIR}"/wpatches ]; then
    echo "Running from repository"

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
    echo "${REQUIRED_VARIABLE_NAME}: ${REQUIRED_VARIABLE_VALUE}"
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
        shift 2
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

  if [ "${COMMAND}" == 'dump' ]; then
    IS_VERBOSE=1
  fi
}

# if [ -z "${COMMAND}" ]; then
#   COMMAND='patch'
# fi

echo "WPatcher :: ${STARTUP_VERSION} :: ${GIT_REPOS}"

load_configuration

parse_command_line "${@}"

fail_if_missing_required_binaries

configure_and_create_directories

fail_if_missing_required_variables

if [ "${REQUESTED_COMPONENT_TYPE}" == 'themes' ] && [ ${IS_THEMES_SUPPORT_ENABLAED} -ne 1 ]; then
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
  elif [ -n "${REQUESTED_COMPONENT_SLUG}" ] && [ "${REQUESTED_COMPONENT_SLUG}" != "${PLUGIN_SLUG}" ]; then
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
