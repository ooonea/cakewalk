#!/bin/sh

# Uninstall script for cake-autorate
#
# See https://codeberg.org/ooonea/cakewalk for more details

# This needs to be encapsulated into a function so that we are sure that
# sh reads all the contents of the shell file before we potentially erase it.
#
# Otherwise the read operation might fail and it won't be able to proceed with
# the script as expected.
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

main() {
	# Set correctness options
	set -eu

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

	# Stop cake-autorate before continuing.
	if [ -x /etc/init.d/cake-autorate ]
	then
		/etc/init.d/cake-autorate stop || :
	fi
	if [ -x /etc/init.d/mqtt-publisher ]
	then
		/etc/init.d/mqtt-publisher stop || :
	fi
	# Do not remove service files while a recorded main process is still live.
	# A lock-only runtime parent is expected and does not block uninstall.
	# shellcheck disable=SC2310  # the predicate's status is the condition
	if instance_is_running /var/run/cake-autorate /proc
	then
		printf "At least one instance of cake-autorate appears to be running - exiting\n" >&2
		printf "If you want to uninstall a cake-autorate, first stop any running instance of cake-autorate\n" >&2
		return 1
	fi
	rm -f /etc/init.d/cake-autorate /etc/rc.d/*cake-autorate
	rm -f /etc/init.d/mqtt-publisher /etc/rc.d/*mqtt-publisher

	# remove configuration files if user does not want to keep them
	keepIt=''
	if [ -d "${CONFIG_PREFIX}" ]
	then
		cd "${CONFIG_PREFIX}"
		for file in *config.*.sh*
		do
			[ -e "${file}" ] || continue
			if [ -z "${keepIt:-}" ]
			then
				printf "Would you like to keep your configs? [Y/n]"
				read -r keepIt
				[ -z "${keepIt:-}" ] && keepIt=Y
			fi
			if [ "${keepIt}" = "N" ] || [ "${keepIt}" = "n" ]
			then
				rm -f "${file}"
			fi
		done
	fi

	# remove old program files from cake-autorate directory
	if [ -d "${SCRIPT_PREFIX}" ]
	then
		cd "${SCRIPT_PREFIX}"
		old_fnames="cake-autorate.sh cake-autorate_defaults.sh cake-autorate_launcher.sh cake-autorate_lib.sh cake-autorate_setup.sh"
		for file in ${old_fnames}
		do
			rm -f "${file}"
		done

		# remove current program files from the cake-autorate directory
		files="cake-autorate.sh defaults.sh launcher.sh lib.sh mqtt-publisher.sh setup.sh uninstall.sh version.txt"
		for file in ${files}
		do
			rm -f "${file}"
		done
	fi
	rm -rf /var/run/cake-autorate

	# remove ${SCRIPT_PREFIX} and ${CONFIG_PREFIX} directories if empty
	rmdir "${SCRIPT_PREFIX}" "${CONFIG_PREFIX}" 2>/dev/null || :

	printf '%s\n' "cake-autorate was uninstalled"
}

# Now that we are sure all code is loaded, we could execute the function
main "${@}"
