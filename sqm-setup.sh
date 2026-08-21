#!/usr/bin/env bash

# sqm-setup.sh — minimal CAKE bring-up for GENERIC LINUX hosts.
#
# On OpenWrt the CAKE qdiscs are created by the SQM package and cake-autorate
# only *adjusts* their bandwidth. A generic Linux router has no SQM, so this
# helper creates exactly the qdiscs that cake-autorate then adjusts:
#
#   - egress CAKE on the WAN interface          (ul_if)
#   - ingress CAKE on an IFB device             (dl_if)
#     fed by a tc ingress redirect from the WAN
#
# Interfaces and the initial (base) shaper rates are read from the SAME instance
# config that cake-autorate.sh uses, so there is a single source of truth. After
# this runs, start cake-autorate normally and it takes over the bandwidth.
#
# Usage:
#   sqm-setup.sh start [CONFIG]   set up the qdiscs   (CONFIG default: ./config.primary.sh)
#   sqm-setup.sh stop  [CONFIG]   tear the qdiscs down
#
# Extra CAKE options (diffserv mode, overhead, rtt, …) may be supplied per
# direction via the optional config variables sqm_dl_cake_opts / sqm_ul_cake_opts.

set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

action=start
case "${1:-}" in
	start | stop)
		action=$1
		shift
		;;
	*) ;; # leave action=start; treat $1 as the config path
esac
config=${1:-${script_dir}/config.primary.sh}

config_basename=${config##*/}
if [[ ! ${config_basename} =~ ^config\.([A-Za-z0-9_-]+)\.sh$ ]]
then
	printf >&2 'sqm-setup.sh: config filename must match config.X.sh with a safe non-empty instance identifier\n'
	exit 1
fi
instance_id=${BASH_REMATCH[1]}

sqm_state_root=${CAKE_AUTORATE_SQM_STATE_DIR:-/run/cake-autorate/sqm}
sqm_state_path="${sqm_state_root}/${instance_id}"
sqm_interfaces_state="${sqm_state_path}/interfaces"
sqm_qdisc_handle=ca1e:
sqm_filter_pref=49152
created_ul_root=0
created_ingress=0
created_ifb=0

if [[ ${action} == start ]]
then
	if [[ ! -f ${config} ]]
	then
		printf >&2 'sqm-setup.sh: config not found: %s\n' "${config}"
		exit 1
	fi

	# Pull dl_if / ul_if and the base rates from defaults + instance config.
	# shellcheck source=/dev/null
	. "${script_dir}/defaults.sh"
	# shellcheck source=/dev/null
	. "${config}"

	: "${dl_if:?sqm-setup.sh: dl_if is not set in the config}"
	: "${ul_if:?sqm-setup.sh: ul_if is not set in the config}"
	: "${base_dl_shaper_rate_kbps:?sqm-setup.sh: base_dl_shaper_rate_kbps is not set}"
	: "${base_ul_shaper_rate_kbps:?sqm-setup.sh: base_ul_shaper_rate_kbps is not set}"

	if [[ ${dl_if} == "${ul_if}" ]]
	then
		printf >&2 'sqm-setup.sh: dl_if and ul_if must name different interfaces\n'
		exit 1
	fi
	if [[ ! ${dl_if} =~ ^[A-Za-z0-9_.:-]+$ || ! ${ul_if} =~ ^[A-Za-z0-9_.:-]+$ ]]
	then
		printf >&2 'sqm-setup.sh: interface names contain unsupported characters\n'
		exit 1
	fi
	if [[ ! ${base_dl_shaper_rate_kbps} =~ ^[1-9][0-9]*$ || ! ${base_ul_shaper_rate_kbps} =~ ^[1-9][0-9]*$ ]]
	then
		printf >&2 'sqm-setup.sh: base shaper rates must be positive decimal integers\n'
		exit 1
	fi

	# Optional per-direction extra CAKE keywords. The defaults give full per-host
	# fairness on a NAT router, like OpenWrt SQM: "nat" resolves the inside hosts,
	# and dual-srchost (egress) / dual-dsthost (ingress) share bandwidth per LAN
	# host, so no single host can starve the others. Override in the config if needed.
	sqm_dl_cake_opts=${sqm_dl_cake_opts:-nat dual-dsthost ingress}
	sqm_ul_cake_opts=${sqm_ul_cake_opts:-nat dual-srchost}
fi

write_state()
{
	local state_tmp="${sqm_interfaces_state}.tmp.${BASHPID}"

	( umask 077 && mkdir -p "${sqm_state_path}" )
	printf '%s\n%s\n' "${ul_if}" "${dl_if}" > "${state_tmp}"
	mv -f "${state_tmp}" "${sqm_interfaces_state}"
}

record_ownership()
{
	: > "${sqm_state_path}/${1}"
}

rollback_current()
{
	local command_status status=0

	trap - ERR
	set +e
	if ((created_ul_root))
	then
		record_ownership ul-root
		command_status=${?}
		((command_status == 0)) || status=1
	fi
	if ((created_ingress))
	then
		record_ownership ingress
		command_status=${?}
		((command_status == 0)) || status=1
	fi
	if ((created_ifb))
	then
		record_ownership ifb
		command_status=${?}
		((command_status == 0)) || status=1
	fi
	if ((status == 0))
	then
		teardown_managed
		status=${?}
	fi
	set -e
	if ((status != 0))
	then
		printf >&2 'sqm-setup.sh: rollback is incomplete; retained ownership state for a later retry\n'
	fi
	return 0
}

teardown_managed()
{
	local managed_interfaces managed_ul_if managed_dl_if managed_ifb_alias qdisc_output filter_output status=0

	[[ -d ${sqm_state_path} ]] || return 0
	if [[ ! -f ${sqm_interfaces_state} ]]
	then
		printf >&2 'sqm-setup.sh: ownership state is incomplete for instance %s; refusing teardown\n' "${instance_id}"
		return 1
	fi
	mapfile -t managed_interfaces < "${sqm_interfaces_state}"
	if ((${#managed_interfaces[@]} != 2)) || [[ ! ${managed_interfaces[0]} =~ ^[A-Za-z0-9_.:-]+$ || ! ${managed_interfaces[1]} =~ ^[A-Za-z0-9_.:-]+$ ]]
	then
		printf >&2 'sqm-setup.sh: ownership state is invalid for instance %s; refusing teardown\n' "${instance_id}"
		return 1
	fi
	managed_ul_if=${managed_interfaces[0]}
	managed_dl_if=${managed_interfaces[1]}
	managed_ifb_alias="cakewalk-sqm:${instance_id}:${managed_ul_if}:${managed_dl_if}"

	if [[ -e ${sqm_state_path}/ingress ]]
	then
		tc filter del dev "${managed_ul_if}" parent ffff: protocol all pref "${sqm_filter_pref}" u32 2>/dev/null || true
		if ! filter_output=$(tc filter show dev "${managed_ul_if}" parent ffff: 2>/dev/null)
		then
			printf >&2 'sqm-setup.sh: could not inspect the marked ingress filter on %s; retaining ownership state\n' "${managed_ul_if}"
			status=1
			filter_output=unknown
		fi
		if grep -Eq "(^|[[:space:]])pref[[:space:]]+${sqm_filter_pref}([[:space:]]|$)" <<< "${filter_output}"
		then
			printf >&2 'sqm-setup.sh: marked ingress filter on %s could not be removed\n' "${managed_ul_if}"
			status=1
		elif [[ -z ${filter_output} ]]
		then
			if tc qdisc del dev "${managed_ul_if}" ingress 2>/dev/null
			then
				rm -f "${sqm_state_path}/ingress"
			else
				printf >&2 'sqm-setup.sh: empty marked ingress qdisc on %s could not be removed\n' "${managed_ul_if}"
				status=1
			fi
		elif [[ ${filter_output} != unknown ]]
		then
			rm -f "${sqm_state_path}/ingress"
		fi
	fi

	if [[ -e ${sqm_state_path}/ul-root ]]
	then
		qdisc_output=$(tc qdisc show root dev "${managed_ul_if}" 2>/dev/null) || qdisc_output=
		if [[ ${qdisc_output} =~ ^qdisc[[:space:]]+(cake_mq|cake)[[:space:]]+${sqm_qdisc_handle}([[:space:]]|$) ]]
		then
			if tc qdisc del root dev "${managed_ul_if}" 2>/dev/null
			then
				rm -f "${sqm_state_path}/ul-root"
			else
				printf >&2 'sqm-setup.sh: marked upload qdisc on %s could not be removed\n' "${managed_ul_if}"
				status=1
			fi
		else
			printf >&2 'sqm-setup.sh: marked upload qdisc on %s no longer has the owned handle; refusing removal\n' "${managed_ul_if}"
			status=1
		fi
	fi

	if [[ -e ${sqm_state_path}/ifb ]]
	then
		if ! ip link show dev "${managed_dl_if}" >/dev/null 2>&1
		then
			rm -f "${sqm_state_path}/ifb"
		elif ip -d link show dev "${managed_dl_if}" 2>/dev/null | grep -Eq '^[[:space:]]*ifb([[:space:]]|$)' &&
			ip link show dev "${managed_dl_if}" 2>/dev/null | grep -Fq "alias ${managed_ifb_alias}"
		then
			if ip link del "${managed_dl_if}" 2>/dev/null
			then
				rm -f "${sqm_state_path}/ifb"
			else
				printf >&2 'sqm-setup.sh: marked download interface %s could not be removed\n' "${managed_dl_if}"
				status=1
			fi
		else
			printf >&2 'sqm-setup.sh: marked download interface %s no longer has the owned IFB identity; refusing removal\n' "${managed_dl_if}"
			status=1
		fi
	fi

	if ((status == 0))
	then
		rm -f "${sqm_interfaces_state}"
		rmdir "${sqm_state_path}" 2>/dev/null || true
		rmdir "${sqm_state_root}" 2>/dev/null || true
	fi
	return "${status}"
}

case ${action} in
	stop)
		teardown_managed
		;;
	start)
		if ! ip link show "${ul_if}" >/dev/null 2>&1; then
			printf >&2 'sqm-setup.sh: WAN interface "%s" (ul_if) not found\n' "${ul_if}"
			exit 1
		fi
		# numifbs=0 so the module doesn't auto-create stray ifb0/ifb1 (which would
		# otherwise pick up IPv4LL 169.254 addresses); we add a named IFB below.
		# (Only takes effect on the module's first load, i.e. a clean boot.)
		modprobe ifb numifbs=0 2>/dev/null || true
		modprobe sch_cake 2>/dev/null || true
		teardown_managed
		write_state
		trap rollback_current ERR

		# Upload: shape egress on the WAN interface.
		# shellcheck disable=SC2086
		tc qdisc add root dev "${ul_if}" handle "${sqm_qdisc_handle}" cake \
			bandwidth "${base_ul_shaper_rate_kbps}kbit" ${sqm_ul_cake_opts}
		created_ul_root=1
		record_ownership ul-root

		# Download: redirect WAN ingress into an IFB and shape that.
		ip link add "${dl_if}" type ifb
		created_ifb=1
		ip link set dev "${dl_if}" alias "cakewalk-sqm:${instance_id}:${ul_if}:${dl_if}"
		record_ownership ifb
		ip link set "${dl_if}" up
		tc qdisc add dev "${ul_if}" handle ffff: ingress
		created_ingress=1
		record_ownership ingress
		tc filter add dev "${ul_if}" parent ffff: protocol all \
			pref "${sqm_filter_pref}" u32 match u32 0 0 action mirred egress redirect dev "${dl_if}"
		# shellcheck disable=SC2086
		tc qdisc add root dev "${dl_if}" handle "${sqm_qdisc_handle}" cake \
			bandwidth "${base_dl_shaper_rate_kbps}kbit" ${sqm_dl_cake_opts}
		trap - ERR
		;;
	*)
		printf >&2 'sqm-setup.sh: unknown action: %s\n' "${action}"
		exit 1
		;;
esac
