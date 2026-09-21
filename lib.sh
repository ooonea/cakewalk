#!/usr/bin/env bash
# shellcheck disable=SC2310,SC2311

# lib.sh -- common functions for use by cake-autorate.sh
#
# This file is part of cake-autorate.

__set_e=0
if [[ ! ${-} =~ e ]]
then
    set -e
    __set_e=1
fi

CAKE_AUTORATE_PROC_ROOT=${CAKE_AUTORATE_PROC_ROOT:-/proc}

if [[ -z ${__sleep_fd:-} ]]
then
	exec {__sleep_fd}<> <(:)
fi

is_unsigned_integer()
{
	[[ ${1} =~ ^(0|[1-9][0-9]*)$ ]]
}

is_nonnegative_decimal()
{
	[[ ${1} =~ ^((0|[1-9][0-9]*)|((0|[1-9][0-9]*)?\.[0-9]+))$ ]]
}

timestamp_value_to_us()
{
	local source_timestamp=${1} seconds fraction

	if [[ ${source_timestamp} == *.* ]]
	then
		seconds=${source_timestamp%%.*}
		fraction=${source_timestamp#*.}
	else
		seconds=${source_timestamp}
		fraction=
	fi

	is_unsigned_integer "${seconds}" || return 1
	[[ -z ${fraction} || ${fraction} =~ ^[0-9]+$ ]] || return 1

	fraction=${fraction:0:6}
	while ((${#fraction} < 6))
	do
		fraction+="0"
	done

	if (($# > 1))
	then
		local -n converted_us_ref=${2}
		# shellcheck disable=SC2034  # assignment is returned through the nameref
		converted_us_ref=${seconds}${fraction}
	else
		printf '%s%s\n' "${seconds}" "${fraction}"
	fi
}

monotonic_time_us()
{
	local uptime _ monotonic_timestamp

	if [[ -r ${CAKE_AUTORATE_PROC_ROOT}/uptime ]] && read -r uptime _ < "${CAKE_AUTORATE_PROC_ROOT}/uptime"
	then
		timestamp_value_to_us "${uptime}" monotonic_timestamp || return
	else
		timestamp_value_to_us "${EPOCHREALTIME}" monotonic_timestamp || return
	fi

	if (($#))
	then
		local -n monotonic_result_ref=${1}
		# shellcheck disable=SC2034  # assignment is returned through the nameref
		monotonic_result_ref=${monotonic_timestamp}
	else
		printf '%s\n' "${monotonic_timestamp}"
	fi
}

sleep_remaining_tick_time_monotonic()
{
	# sleeps until the end of the tick duration using the monotonic clock when
	# /proc/uptime is available

	# ${1} = t_start_us (microseconds)
	# ${2} = tick_duration_us (microseconds)

	local now_us

	monotonic_time_us now_us || now_us=${EPOCHREALTIME/.}

	((
		sleep_duration_us=${1} + ${2} - now_us,
		sleep_duration_us < 0 && (sleep_duration_us=0)
	))

	printf -v sleep_duration_s %.1f "${sleep_duration_us}e-6"
	read -r -t "${sleep_duration_s}" -u "${__sleep_fd}" || :
}

bracketed_timestamp_to_us()
{
	local timestamp=${1}

	[[ ${timestamp} == \[*\] ]] || return 1
	timestamp=${timestamp:1:${#timestamp}-2}
	timestamp_value_to_us "${timestamp}"
}

normalise_pinger_timestamp_us()
{
	local method=${1} timestamp=${2}

	case ${method} in
		irtt)
			is_unsigned_integer "${timestamp}" || return 1
			printf '%s\n' "${timestamp}"
			;;
		tsping)
			timestamp_value_to_us "${timestamp}"
			;;
		fping|fping-ts|ping)
			bracketed_timestamp_to_us "${timestamp}"
			;;
		*)
			return 1
			;;
	esac
}

pinger_timestamp_is_fresh()
{
	local timestamp_us=${1} now_us=${2} max_age_us=${3:-500000}

	is_unsigned_integer "${timestamp_us}" &&
		is_unsigned_integer "${now_us}" &&
		is_unsigned_integer "${max_age_us}" || return 1

	# All supported pingers timestamp locally. A future timestamp can otherwise
	# suppress reflector health checks just as an old queued response can drive
	# state, so accept only the bounded interval ending at the current sample.
	(( now_us >= 10#${timestamp_us} && now_us - 10#${timestamp_us} <= max_age_us ))
}

valid_irtt_reply_fields()
{
	local -n fields=${1}

	((${#fields[@]} == 5)) &&
		is_unsigned_integer "${fields[0]}" &&
		is_unsigned_integer "${fields[2]}" &&
		is_unsigned_integer "${fields[3]}" &&
		is_unsigned_integer "${fields[4]}"
}

valid_tsping_reply_fields()
{
	local -n fields=${1}

	((${#fields[@]} == 10)) &&
		is_nonnegative_decimal "${fields[8]}" &&
		is_nonnegative_decimal "${fields[9]}"
}

valid_fping_reply_fields()
{
	local -n fields=${1}

	((${#fields[@]} == 12)) &&
		[[ ${fields[2]} == ":" && ${fields[3]} =~ ^\[(0|[1-9][0-9]*)\]$ && ${fields[5]} == "bytes" && ${fields[7]} == "ms" ]] &&
		is_unsigned_integer "${fields[4]}" &&
		is_nonnegative_decimal "${fields[6]}"
}

valid_fping_ts_reply_fields()
{
	local -n fields=${1}

	((${#fields[@]} == 17)) &&
		[[ ${fields[13]} == Originate=* && ${fields[14]} == Receive=* && ${fields[15]} == Transmit=* && ${fields[16]} == Localreceive=* ]] &&
		is_unsigned_integer "${fields[13]#Originate=}" &&
		is_unsigned_integer "${fields[14]#Receive=}" &&
		is_unsigned_integer "${fields[15]#Transmit=}" &&
		is_unsigned_integer "${fields[16]#Localreceive=}"
}

valid_ping_reply_fields()
{
	local -n fields=${1}

	((${#fields[@]} == 9)) &&
		[[ ${fields[2]} == "bytes" && ${fields[3]} == "from" && ${fields[5]} =~ ^icmp_seq=(0|[1-9][0-9]*)$ && ${fields[7]} == time=* && ${fields[8]} == "ms" ]] &&
		is_unsigned_integer "${fields[1]}" &&
		is_nonnegative_decimal "${fields[7]#time=}"
}

valid_tagged_ping_reply_fields()
{
	local -n fields=${1} active_reflectors=${2}
	local pinger_index=${fields[1]:-}
	local reply_fields=()

	((${#fields[@]} == 12)) &&
		[[ ${fields[0]} == PING ]] &&
		is_unsigned_integer "${pinger_index}" &&
		(( 10#${pinger_index} < ${#active_reflectors[@]} )) &&
		[[ ${fields[2]} == "${active_reflectors[10#${pinger_index}]}" ]] || return 1

	# shellcheck disable=SC2034  # read through the valid_ping_reply_fields nameref
	reply_fields=("${fields[@]:3}")
	valid_ping_reply_fields reply_fields
}

validate_bytes_path()
{
	local name=${1} path=${2}

	if [[ -z ${path} ]]
	then
		log_msg "ERROR" "${name} cannot be empty. Exiting script."
		exit 1
	fi
	if [[ ${path} != /* ]]
	then
		log_msg "ERROR" "${name} must be an absolute path: '${path}'. Exiting script."
		exit 1
	fi
	if [[ ${path} == *$'\n'* || ${path} == *$'\r'* ]]
	then
		log_msg "ERROR" "${name} contains a newline. Exiting script."
		exit 1
	fi
	if [[ -d ${path} ]]
	then
		log_msg "ERROR" "${name} points to a directory, not a byte-counter file: '${path}'. Exiting script."
		exit 1
	fi
}

read_bytes_counter()
{
	local path=${1} counter_value
	local -n output_var=${2}

	read -r counter_value < "${path}" 2>/dev/null || return 1
	is_unsigned_integer "${counter_value}" || return 1
	# shellcheck disable=SC2034  # nameref assignment updates the caller's variable
	output_var=${counter_value}
}

update_achieved_rate()
{
	local path=${1} now_us=${2} fallback_interval_us=${3} current_bytes elapsed_us
	local -n previous_bytes_ref=${4} previous_time_us_ref=${5} initialized_ref=${6} achieved_rate_kbps_ref=${7}

	if ! read_bytes_counter "${path}" current_bytes
	then
		achieved_rate_kbps_ref=0
		return 1
	fi

	if (( ! initialized_ref ))
	then
		previous_bytes_ref=${current_bytes}
		previous_time_us_ref=${now_us}
		initialized_ref=1
		achieved_rate_kbps_ref=0
		return 0
	fi

	(( elapsed_us = now_us - previous_time_us_ref ))
	(( elapsed_us > 0 )) || elapsed_us=${fallback_interval_us}
	((
		achieved_rate_kbps_ref = 8000*(current_bytes - previous_bytes_ref) / elapsed_us,
		achieved_rate_kbps_ref < 0 && (achieved_rate_kbps_ref=0),
		previous_bytes_ref=current_bytes,
		previous_time_us_ref=now_us
	))
}

get_process_start_time()
{
	local pid=${1}

	[[ ${pid} =~ ^[0-9]+$ && -r ${CAKE_AUTORATE_PROC_ROOT}/${pid}/stat ]] || return 1
	awk '
		{
			stat_line = $0
			sub(/^[^)]*\) /, "", stat_line)
			split(stat_line, fields, " ")
			if (fields[20] ~ /^[0-9]+$/) {
				print fields[20]
				exit 0
			}
			exit 1
		}
	' "${CAKE_AUTORATE_PROC_ROOT}/${pid}/stat"
}

typeof() 
{
	# typeof -- returns the type of a variable

	local type_sig
	type_sig=$(declare -p "${1}" 2>/dev/null)
	if [[ "${type_sig}" =~ "declare --" ]]
	then
		str_type "${1}"
	elif [[ "${type_sig}" =~ "declare -a" ]]
	then
		printf "array"
	elif [[ "${type_sig}" =~ "declare -A" ]]
	then
		printf "map"
	else
		printf "none"
	fi
}

str_type() 
{
	# str_type -- returns the type of a string

	local -n str=${1}

	if is_unsigned_integer "${str}"
	then
		printf "integer"
	elif is_nonnegative_decimal "${str}" && [[ ${str} == *.* ]]
	then
		printf "float"
	elif [[ "${str}" =~ ^-(0|[1-9][0-9]*)$ ]]
	then
		printf "negative-integer"
	elif [[ "${str}" =~ ^-((0|[1-9][0-9]*)?\.[0-9]+)$ ]]
	then
		printf "negative-float"
	else
		# technically not validated, user is just trusted to call
		# this function with valid strings
		printf "string"
	fi
}

sleep_s()
{
	# Calling the external sleep binary could be rather slow,
	# especially as it is called very frequently and typically on mediocre hardware.
	#
	# bash's loadable sleep module is not typically available
	# in OpenWRT and most embedded systems, and use of the bash
	# read command with a timeout offers performance that is
	# at least on a par with bash's sleep module.
	#
	# For benchmarks, check the following links:
	# - https://github.com/lynxthecat/cake-autorate/issues/174#issuecomment-1460057382
	# - https://github.com/lynxthecat/cake-autorate/issues/174#issuecomment-1460074498

	# ${1} = sleep_duration_s (seconds, e.g. 0.5, 1 or 1.5)

	read -r -t "${1}" -u "${__sleep_fd}" || :
}

sleep_us()
{
	# ${1} = sleep_duration_us (microseconds)

	printf -v sleep_duration_s %.1f "${1}e-6"
	read -r -t "${sleep_duration_s}" -u "${__sleep_fd}" || :
}

randomize_array()
{
	# randomize the order of the elements of an array
	# see: https://en.wikipedia.org/wiki/Fisher%E2%80%93Yates_shuffle

	local -n array=${1}

	for ((set=${#array[@]}-1; set>0; set--))
	do
		# j must be in [0, set] inclusive for unbiased Fisher-Yates (RANDOM%set alone
		# is Sattolo's -- biased).
		idx=$((RANDOM%(set+1)))
		temp=${array[set]}
		array[set]=${array[idx]}
		array[idx]=${temp}
	done
}

generate_run_token()
{
	local run_token

	read -r run_token < "${CAKE_AUTORATE_PROC_ROOT}/sys/kernel/random/uuid" 2>/dev/null || return 1
	[[ ${run_token} =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 1

	printf '%s\n' "${run_token}"
}

get_running_main_pid_for_run_path()
{
	local run_path=${1} running_main_pid running_main_start_time current_start_time

	[[ -f ${run_path}/proc_pids ]] || return 1
	[[ -f ${run_path}/run_token ]] || return 1
	running_main_pid=$(awk -F= '/^main=/ {print $2}' "${run_path}/proc_pids") || return 1
	[[ ${running_main_pid} =~ ^[0-9]+$ && -d ${CAKE_AUTORATE_PROC_ROOT}/${running_main_pid} ]] || return 1
	running_main_start_time=$(awk -F= '/^main_starttime=/ {print $2}' "${run_path}/proc_pids") || return 1
	if [[ -n ${running_main_start_time} ]]
	then
		[[ ${running_main_start_time} =~ ^[0-9]+$ ]] || return 1
		current_start_time=$(get_process_start_time "${running_main_pid}") || return 1
		[[ ${current_start_time} == "${running_main_start_time}" ]] || return 1
	fi

	printf '%s\n' "${running_main_pid}"
}

terminate()
{
	# Send regular kill to processes and monitor terminations;
	# return as soon as all of the active processes terminate;
	# if any processes remain active after timeout (defaults to one second),
	# then kill with fire using kill -9;
	# and, finally, call wait on all processes to reap any zombie processes.

	local pids=${1} timeout_ms=${2:-1000}
	local wait_pids=() pid wait_pid

	read -r -a pids <<< "${pids}"
	((${#pids[@]})) || return

	for pid in "${pids[@]}"
	do
		wait_pid=${pid#-}
		[[ ${wait_pid} =~ ^[0-9]+$ ]] && wait_pids+=("${wait_pid}")
	done

	# `--` is required: irtt pids are negated pgids, and kill would otherwise parse
	# the leading `-` as a signal spec.
	kill -TERM -- "${pids[@]}" 2> /dev/null
	# A blocked log reader may defer its TERM trap until the next delimiter.
	[[ -z ${3:-} ]] || printf '\0' >&"${3}"

	for ((i=0; i<timeout_ms; i+=100))
	do
		for process in "${!pids[@]}"
		do
			kill -0 "${pids[${process}]}" 2> /dev/null || unset "pids[${process}]"
		done
		if [[ -z "${pids[*]}" ]]
		then
			((${#wait_pids[@]})) && wait "${wait_pids[@]}" 2>/dev/null || :
			return
		fi
		sleep_s 0.1
	done

	# A process can exit after the final kill -0 probe and before this fallback.
	# That is a successful termination, not an errexit-worthy failure.
	kill -KILL -- "${pids[@]}" 2> /dev/null || :
	((${#wait_pids[@]})) && wait "${wait_pids[@]}" 2>/dev/null || :
}

if (( __set_e == 1 ))
then
    set +e
fi
unset __set_e
