#!/bin/sh

# Capabilities:
#   - CAKE_AUTORATE_SETUP_SH_SUPPORT_SELF_REPLACING

# Installation script for cake-autorate
#
# See https://codeberg.org/ooonea/cakewalk for more details

# Tries curl first, then falls back to wget.
# This is so that users can specify proxy settings via
# environment variables like http_proxy, https_proxy, etc.
download_url() {
	url="${1}"
	if type curl >/dev/null 2>&1; then
		curl -sSL "${url}"
	elif type wget >/dev/null 2>&1; then
		wget -qO- "${url}"
	else
		printf >&2 "Error: Neither curl nor wget is available\n"
		return 1
	fi
}

instance_is_running()
{
	runtime_parent_path=${1}
	proc_root=${2}

	for proc_pids_path in "${runtime_parent_path}"/*/proc_pids
	do
		[ -f "${proc_pids_path}" ] || continue
		main_pid=$(sed -n 's/^main=\([0-9][0-9]*\)$/\1/p' "${proc_pids_path}" | sed -n '1p')
		[ -n "${main_pid}" ] && [ -d "${proc_root}/${main_pid}" ] || continue
		main_starttime=$(sed -n 's/^main_starttime=\([0-9][0-9]*\)$/\1/p' "${proc_pids_path}" | sed -n '1p')
		[ -n "${main_starttime}" ] || return 0
		current_starttime=$(awk '{ stat_line=$0; sub(/^[^)]*\) /, "", stat_line); split(stat_line, fields, " "); print fields[20]; exit }' "${proc_root}/${main_pid}/stat" 2>/dev/null) || return 0
		[ "${current_starttime}" = "${main_starttime}" ] && return 0
	done

	return 1
}

# This needs to be encapsulated into a function so that we are sure that
# sh reads all the contents of the shell file before we potentially erase it.
#
# Otherwise the read operation might fail and it won't be able to proceed with
# the script as expected.
main() {
	# Set correctness options
	set -eu

	# Setup dependencies to check for
	DEPENDENCIES="jsonfilter tar grep cmp mktemp bash flock"

	# Set up remote locations and branch. The repository override remains useful
	# for testing another compatible Codeberg repository.
	BRANCH="${CAKE_AUTORATE_BRANCH:-${2-main}}"
	REPOSITORY="${CAKE_AUTORATE_REPO:-${1-ooonea/cakewalk}}"
	SRC_DIR="https://codeberg.org/${REPOSITORY}/archive"
	API_URL="https://codeberg.org/api/v1/repos/${REPOSITORY}/branches/${BRANCH}"
	DOC_URL="https://codeberg.org/${REPOSITORY}/src/branch/${BRANCH}/INSTALLATION.md"

	# Set SCRIPT_PREFIX and CONFIG_PREFIX
	SCRIPT_PREFIX=${CAKE_AUTORATE_SCRIPT_PREFIX:-}
	CONFIG_PREFIX=${CAKE_AUTORATE_CONFIG_PREFIX:-}

	# Store what OS we are running on
	MY_OS=unknown

	# Check if OS is OpenWRT or derivative
	# (openwrt itself sets ID; derivatives set ID_LIKE - check both)
	unset ID ID_LIKE

	# The following formulations seem to be problematic for some sh versions:
	# - `. /not_found || true`
	# - set +e; . /etc/os-release 2>/dev/null; set -e
	# but this seems to work OK:
	[ -e "/etc/os-release" ] && . /etc/os-release

	for x in ${ID:-} ${ID_LIKE:-}
	do
		if [ "${x}" = "openwrt" ]
		then
			MY_OS=openwrt
			[ -z "${SCRIPT_PREFIX}" ] && SCRIPT_PREFIX=/root/cake-autorate
			[ -z "${CONFIG_PREFIX}" ] && CONFIG_PREFIX=/root/cake-autorate
			break
		fi
	done

	# Check if OS is ASUSWRT-Merlin
	if [ "$(uname -o)" = "ASUSWRT-Merlin" ]
	then
		MY_OS=asuswrt
		[ -z "${SCRIPT_PREFIX}" ] && SCRIPT_PREFIX=/jffs/scripts/cake-autorate
		[ -z "${CONFIG_PREFIX}" ] && CONFIG_PREFIX=/jffs/configs/cake-autorate
	fi

	# If we are not running on OpenWRT or ASUSWRT-Merlin, exit
	if [ "${MY_OS}" = "unknown" ]
	then
		printf "This script requires OpenWrt or ASUSWRT-Merlin\n" >&2
		return 1
	fi

	# A flock backing file may legitimately keep this parent directory present
	# after an instance exits. Block installation only for an actual recorded
	# main process, never because a stale runtime directory merely exists.
	# shellcheck disable=SC2310  # the predicate's status is the condition
	if instance_is_running /var/run/cake-autorate /proc
	then
		printf "At least one instance of cake-autorate appears to be running - exiting\n" >&2
		printf "If you want to install a new version, first stop any running instance of cake-autorate\n" >&2
		exit 1
	fi

	# Check for required setup.sh script dependencies
	exit_now=0
	for dep in ${DEPENDENCIES}
	do
		if ! type "${dep}" >/dev/null 2>&1; then
			printf >&2 "%s is required, please install it and rerun the script!\n" "${dep}"
			exit_now=1
		fi
	done
	dep_found=0
	for dep in curl wget
	do
		if type "${dep}" >/dev/null 2>&1; then
			dep_found=1
			break
		fi
	done
	if [ "${dep_found}" -eq 0 ]; then
		printf >&2 "Either curl or wget is required, please install one of them and rerun the script!\n"
		exit_now=1
	fi
	[ "${exit_now}" -ge 1 ] && exit "${exit_now}"
	if ! bash -c '((BASH_VERSINFO[0] >= 5))'
	then
		printf >&2 "Bash 5.0 or newer is required; please upgrade Bash and rerun the script.\n"
		exit 1
	fi

	# Check for fping, which is required by default
	if ! type "fping" >/dev/null 2>&1; then
		printf "Warning, fping is required by default, but it is not installed.\n"
		printf "So cake-autorate will not run with default settings.\n"
		printf "Either install fping or ensure that one of the other supported ping binaries is installed and selected in the config(s).\n"
	fi

	# Create the cake-autorate directory if it does not exist
	mkdir -p "${SCRIPT_PREFIX}" "${CONFIG_PREFIX}"

	# Resolve an exact commit unless the caller supplied a reviewed pin.
	if [ -n "${__CAKE_AUTORATE_SETUP_SH_EXEC_COMMIT:-}" ]
	then
		commit="${__CAKE_AUTORATE_SETUP_SH_EXEC_COMMIT}"
	elif [ -n "${CAKE_AUTORATE_COMMIT:-}" ]
	then
		commit="${CAKE_AUTORATE_COMMIT}"
	else
		commit=$(download_url "${API_URL}" | jsonfilter -e @.commit.id)
	fi
	if [ -z "${commit:-}" ];
	then
		printf >&2 "Unable to resolve a commit for %s:%s\n" "${REPOSITORY}" "${BRANCH}"
		exit 1
	fi
	case "${commit}" in
		*[!0-9a-fA-F]*)
			printf >&2 "Resolved commit is not a hexadecimal SHA-1: %s\n" "${commit}"
			exit 1
			;;
		*) ;;
	esac
	if [ "${#commit}" -ne 40 ]
	then
		printf >&2 "Resolved commit is not a 40-character SHA-1: %s\n" "${commit}"
		exit 1
	fi

	printf "Detected Operating System: %s\n" "${MY_OS}"
	printf "Installation directories for detected Operating System:\n"
	printf "  - Script prefix: %s\n" "${SCRIPT_PREFIX}"
	printf "  - Config prefix: %s\n" "${CONFIG_PREFIX}"

	printf "Continue with installation? [Y/n] "

	read -r continue_installation
	if [ "${continue_installation}" = "N" ] || [ "${continue_installation}" = "n" ]
	then
		exit
	fi

	printf "Installing cake-autorate using %s (script) and %s (config) directories...\n" "${SCRIPT_PREFIX}" "${CONFIG_PREFIX}"

	# Download the selected commit and strip the archive's one top-level directory.
	if [ -z "${__CAKE_AUTORATE_SETUP_SH_EXEC_TMP:-}" ]
	then
		tmp=$(mktemp -d)
		archive="${tmp}/archive.tar.gz"
		download_url "${SRC_DIR}/${commit}.tar.gz" > "${archive}"
		tar -xozf "${archive}" -C "${tmp}"
		rm -f "${archive}"
		archive_root=
		for candidate in "${tmp}"/*
		do
			[ -d "${candidate}" ] || continue
			archive_root="${candidate}"
			break
		done
		[ -n "${archive_root}" ] || {
			printf >&2 "Downloaded archive has no top-level directory\n"
			exit 1
		}
		mv "${archive_root}"/* "${tmp}"
		for hidden in "${archive_root}"/.[!.]* "${archive_root}"/..?*
		do
			[ -e "${hidden}" ] || continue
			mv "${hidden}" "${tmp}"
		done
		rmdir "${archive_root}"
	else
		tmp="${__CAKE_AUTORATE_SETUP_SH_EXEC_TMP}"
	fi
	trap 'rm -rf "${tmp}"' EXIT INT TERM

	# Compare local setup.sh with the one from the repository
	if [ -e "${tmp}/setup.sh" ] && [ -e "${0}" ] && ! cmp -s "${0}" "${tmp}/setup.sh"
	then
		printf "Local setup.sh differs from the one in the repository\n"
		if grep -q ' CAKE_AUTORATE_SETUP_SH_SUPPORT_SELF_REPLACING$' "${tmp}/setup.sh"
		then
			printf "Self-replacing setup.sh and restarting while preserving the current environment...\n"
			trap - EXIT INT TERM
			__CAKE_AUTORATE_SETUP_SH_EXEC_TMP="${tmp}" \
			__CAKE_AUTORATE_SETUP_SH_EXEC_COMMIT="${commit}" \
				exec "${tmp}/setup.sh" "${REPOSITORY}" "${BRANCH}"
		else
			printf "Self-replacing not fully supported. Running the downloaded setup.sh as a child...\n"
			sh "${tmp}/setup.sh" "${REPOSITORY}" "${BRANCH}"
			exit "${?}"
		fi

		exit "${?}"  # should not reach this point
	fi

	# Migrate old configuration (and new file) files if present
	cd "${CONFIG_PREFIX}"
	for file in cake-autorate_config.*.sh*
	do
		[ -e "${file}" ] || continue   # handle case where there are no old config files
		new_fname="$(printf '%s\n' "${file}" | cut -c15-)"
		mv "${file}" "${new_fname}"
	done

	# Check if a configuration file exists, and ask whether to keep it
	cd "${CONFIG_PREFIX}"
	editmsg="\nNow edit the config.primary.sh file as described in:\n   ${DOC_URL}"
	if [ -f config.primary.sh ]
	then
		printf "Previous configuration present - keep it? [Y/n] "
		read -r keep_previous_configuration
		if [ "${keep_previous_configuration}" = "N" ] || [ "${keep_previous_configuration}" = "n" ]; then
			mv "${tmp}/config.primary.sh" config.primary.sh
			rm -f config.primary.sh.new   # delete config.primary.sh.new if exists
		else
			editmsg="Using prior configuration"
			mv "${tmp}/config.primary.sh" config.primary.sh.new
		fi
	else
		mv "${tmp}/config.primary.sh" config.primary.sh
	fi
	mv "${tmp}/mqtt-config.sh.example" "${CONFIG_PREFIX}/mqtt-config.sh.example"

	# remove old program files from cake-autorate directory
	cd "${SCRIPT_PREFIX}"
	old_fnames="cake-autorate.sh cake-autorate_defaults.sh cake-autorate_launcher.sh cake-autorate_lib.sh cake-autorate_setup.sh"
	for file in ${old_fnames}
	do
		rm -f "${file}"
	done

	# move the program files to the cake-autorate directory
	# scripts that need to be executable are already marked as such in the tarball
	cd "${SCRIPT_PREFIX}"
	files="cake-autorate.sh defaults.sh lib.sh mqtt-publisher.sh setup.sh uninstall.sh"
	for file in ${files}
	do
		mv "${tmp}/${file}" "${file}"
	done

	# Generate a launcher.sh file from the launcher.sh.template file
	sed -e "s|%%SCRIPT_PREFIX%%|${SCRIPT_PREFIX}|g" -e "s|%%CONFIG_PREFIX%%|${CONFIG_PREFIX}|g" \
		"${tmp}/launcher.sh.template" > "${SCRIPT_PREFIX}/launcher.sh"
	chmod +x "${SCRIPT_PREFIX}/launcher.sh"

	# Also for OpenWrt generate the service files from templates but DO NOT ACTIVATE THEM
	if [ "${MY_OS}" = "openwrt" ]
	then
		sed "s|%%SCRIPT_PREFIX%%|${SCRIPT_PREFIX}|g" "${tmp}/cake-autorate.template" > /etc/init.d/cake-autorate
		chmod +x /etc/init.d/cake-autorate
		sed -e "s|%%SCRIPT_PREFIX%%|${SCRIPT_PREFIX}|g" -e "s|%%CONFIG_PREFIX%%|${CONFIG_PREFIX}|g" \
			"${tmp}/mqtt-publisher.template" > /etc/init.d/mqtt-publisher
		chmod +x /etc/init.d/mqtt-publisher
	fi

	# Get version and generate a file containing version information
	cd "${SCRIPT_PREFIX}"
	version=$(grep -m 1 ^cake_autorate_version= "${SCRIPT_PREFIX}/cake-autorate.sh" | cut -d= -f2 | cut -d'"' -f2)
	cat > version.txt <<-EOF
		version=${version}
		commit=${commit}
	EOF

	# Tell how to handle the config file - use old, or edit the new one
	# shellcheck disable=SC2059
	printf "${editmsg}\n"

	printf '\n%s\n\n' "${version} successfully installed, but not yet running"
	printf '%s\n' "Start the software manually with:"
	printf '%s\n' "   cd ${SCRIPT_PREFIX}; ./cake-autorate.sh"

	case "${MY_OS}" in

		"openwrt")
			printf '%s\n' "Run as a service with:"
			printf '%s\n\n' "   service cake-autorate enable; service cake-autorate start"
			;;
		"asuswrt")
			printf '%s\n' "Launch script on boot with:"
			printf '%s\n' "   echo ${SCRIPT_PREFIX}/launcher.sh > /opt/etc/init.d/S99cake-autorate"
			printf '%s\n' "   chmod +x /opt/etc/init.d/S99cake-autorate"
			printf '%s\n\n' "See also: https://github.com/RMerl/asuswrt-merlin.ng/wiki/User-scripts"
			;;
		*)
			;;
	esac
}

# Now that we are sure all code is loaded, we could execute the function
main "${@}"
