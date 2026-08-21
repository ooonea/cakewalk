#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2310

set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=../lib.sh
. "${repo_dir}/lib.sh"

tmp_root=$(mktemp -d)

cleanup_tmp_dirs()
{
	rm -rf "${tmp_root}"
}

trap cleanup_tmp_dirs EXIT

make_tmp_dir()
{
	mktemp -d "${tmp_root}/case.XXXXXXXXXX"
}

fail()
{
	printf 'not ok - %s\n' "${1}" >&2
	exit 1
}

ok()
{
	printf 'ok - %s\n' "${1}"
}

assert_eq()
{
	local expected=${1} actual=${2} context=${3}

	[[ ${actual} == "${expected}" ]] || fail "${context}: expected '${expected}', got '${actual}'"
}

assert_success()
{
	local context=${1}
	shift

	"$@" || fail "${context}: command failed"
}

assert_failure()
{
	local context=${1}
	shift

	if "$@"
	then
		fail "${context}: command unexpectedly succeeded"
	fi
}

extract_function()
{
	local function_name=${1}

	awk -v function_name="${function_name}" '
		$0 == function_name "()" {
			printing = 1
			seen_open = 0
			depth = 0
		}
		printing {
			print
			for (i = 1; i <= length($0); i++) {
				ch = substr($0, i, 1)
				if (ch == "{") {
					depth++
					seen_open = 1
				} else if (ch == "}") {
					depth--
				}
			}
			if (seen_open && depth == 0) {
				exit
			}
		}
	' "${repo_dir}/cake-autorate.sh"
}

log_msg()
{
	:
}

eval "$(extract_function get_root_qdisc_kind)"
eval "$(extract_function set_shaper_rate)"
eval "$(extract_function export_proc_pids)"
eval "$(extract_function acquire_startup_lock)"
eval "$(extract_function release_startup_lock)"
eval "$(extract_function runtime_path_is_safe)"
eval "$(extract_function derive_instance_run_path)"
eval "$(extract_function validate_operational_bounds)"
eval "$(extract_function cleanup_and_killall)"
eval "$(extract_function kill_pinger)"
eval "$(extract_function stop_pingers)"
eval "$(extract_function get_max_wire_packet_size_bits)"

write_fake_stat()
{
	local proc_root=${1} pid=${2} start_time=${3}

	mkdir -p "${proc_root}/${pid}"
	printf '%s (bash) S 1 1 1 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n' "${pid}" "${start_time}" > "${proc_root}/${pid}/stat"
}

test_numeric_validation()
{
	local value

	value=8
	assert_eq integer "$(str_type value)" "plain decimal integer"
	value=0
	assert_eq integer "$(str_type value)" "zero integer"
	value=08
	assert_eq string "$(str_type value)" "leading-zero integer rejected"
	value=0.5
	assert_eq float "$(str_type value)" "decimal float"
	value=.5
	assert_eq float "$(str_type value)" "leading-dot decimal float"
	value=01.5
	assert_eq string "$(str_type value)" "leading-zero float rejected"
	value=1e3
	assert_eq string "$(str_type value)" "scientific notation rejected"

	assert_success "decimal RTT accepted" is_nonnegative_decimal 12.345
	assert_failure "leading-zero decimal rejected" is_nonnegative_decimal 08.1
	assert_failure "non-decimal rejected" is_nonnegative_decimal 1e3

	ok "numeric validation"
}

test_runtime_requires_flock()
{
	local status

	set +e
	env PATH=/nonexistent "${BASH}" "${repo_dir}/cake-autorate.sh" >/dev/null 2>&1
	status=${?}
	set -e
	assert_eq 1 "${status}" "runtime fails loud when flock is unavailable"

	ok "runtime flock dependency"
}

test_bash_requirement()
{
	grep -Fqx 'if ((BASH_VERSINFO[0] < 5))' "${repo_dir}/cake-autorate.sh" || fail "daemon Bash 5 guard missing"
	grep -Eq '^[[:space:]]*if \(\(BASH_VERSINFO\[0\] < 5\)\)$' "${repo_dir}/launcher.sh.template" || fail "launcher Bash 5 guard missing"
	grep -Fq "bash -c '((BASH_VERSINFO[0] >= 5))'" "${repo_dir}/setup.sh" || fail "installer Bash 5 guard missing"
	grep -Fq 'Bash 5.0 or newer' "${repo_dir}/INSTALLATION.md" || fail "installation Bash 5 documentation missing"

	ok "Bash 5 requirement"
}

test_pinger_field_validation()
{
	local -a command

	IFS=" ," read -r -a command <<< "[123.456789] 64 bytes from 1.1.1.1: icmp_seq=7 ttl=55 time=12.345 ms"
	assert_success "valid ping reply accepted" valid_ping_reply_fields command
	assert_eq 123456789 "$(normalise_pinger_timestamp_us ping "${command[0]}")" "ping timestamp normalised"

	IFS=" ," read -r -a command <<< "[123.456789] From 1.1.1.1 icmp_seq=7 Destination Host Unreachable"
	assert_failure "ping error line rejected" valid_ping_reply_fields command

	IFS=" ," read -r -a command <<< "[123.456789] 64 bytes from 1.1.1.1: icmp_seq=08 ttl=55 time=12.345 ms"
	assert_failure "ping leading-zero sequence rejected" valid_ping_reply_fields command

	IFS=" ," read -r -a command <<< "[123.456789] 64 bytes from 1.1.1.1: icmp_seq=7 ttl=55 time=abc ms"
	assert_failure "ping non-numeric time rejected" valid_ping_reply_fields command
	assert_failure "unbracketed ping timestamp rejected" normalise_pinger_timestamp_us ping 123.456789
	assert_success "current pinger timestamp accepted" pinger_timestamp_is_fresh 123456789 123500000
	assert_failure "stale pinger timestamp rejected" pinger_timestamp_is_fresh 122999999 123500000
	assert_failure "future pinger timestamp rejected" pinger_timestamp_is_fresh 123500001 123500000

	IFS=" ," read -r -a command <<< "[123.45] 1.1.1.1 : [7], 64 bytes, 12.345 ms (12.345 avg, 0% loss)"
	assert_success "valid fping reply accepted" valid_fping_reply_fields command
	assert_eq 123450000 "$(normalise_pinger_timestamp_us fping "${command[0]}")" "fping timestamp padded"

	IFS=" ," read -r -a command <<< "[123.45] 1.1.1.1 : [7], 64 bytes, -1.0 ms (-1.0 avg, 0% loss)"
	assert_failure "negative fping RTT rejected" valid_fping_reply_fields command

	command=(123456789 reflector.example 7 123 456)
	assert_success "valid irtt reply accepted" valid_irtt_reply_fields command
	command=(123.456 reflector.example 7 0 0 0 0 0 12.5 13.5)
	assert_success "valid tsping reply accepted" valid_tsping_reply_fields command
	command=(123.456 reflector.example 7 0 0 0 0 0 12.5 NaN)
	assert_failure "malformed tsping reply rejected" valid_tsping_reply_fields command
	command=("[123.45]" reflector.example : "[7]" 64 bytes 0 ms ignored ignored ignored ignored ignored Originate=1 Receive=2 Transmit=3 Localreceive=4)
	assert_success "valid fping-ts reply accepted" valid_fping_ts_reply_fields command
	command[16]=Localreceive=NaN
	assert_failure "malformed fping-ts reply rejected" valid_fping_ts_reply_fields command

	ok "pinger field validation"
}

test_bytes_counter_validation()
{
	local tmp counter value

	tmp=$(make_tmp_dir)

	counter="${tmp}/rx_bytes"
	printf '%s\n' 12345 > "${counter}"
	assert_success "decimal counter accepted" read_bytes_counter "${counter}" value
	assert_eq 12345 "${value}" "counter value read"

	printf '%s\n' 0123 > "${counter}"
	assert_failure "leading-zero counter rejected" read_bytes_counter "${counter}" value

	assert_success "absolute counter path accepted" validate_bytes_path rx_bytes_path "${counter}"
	assert_failure "relative counter path rejected" bash -c "$(declare -f log_msg validate_bytes_path); validate_bytes_path rx_bytes_path relative/path"
	assert_failure "directory counter path rejected" bash -c "$(declare -f log_msg validate_bytes_path); validate_bytes_path rx_bytes_path '${tmp}'"

	ok "byte counter validation"
}

test_atomic_proc_metadata_with_fake_proc()
{
	local tmp fake_proc observed

	tmp=$(make_tmp_dir)

	run_path="${tmp}/run"
	mkdir "${run_path}"
	fake_proc="${tmp}/proc"
	write_fake_stat "${fake_proc}" 123 123123
	write_fake_stat "${fake_proc}" 456 456456
	CAKE_AUTORATE_PROC_ROOT=${fake_proc}

	CAKE_AUTORATE_RUN_TOKEN=11111111-2222-3333-4444-555555555555
	export CAKE_AUTORATE_RUN_TOKEN
	declare -gA proc_pids
	proc_pids=([main]=123 [monitor_achieved_rates]=456)

	assert_success "proc metadata export succeeds" export_proc_pids
	[[ -f ${run_path}/run_token && -f ${run_path}/proc_pids ]] || fail "metadata files missing"
	! compgen -G "${run_path}"'/*.tmp.*' >/dev/null || fail "temporary metadata files left behind"
	grep -Fxq 'main=123' "${run_path}/proc_pids" || fail "main pid missing from proc metadata"
	grep -Fxq 'main_starttime=123123' "${run_path}/proc_pids" || fail "main starttime missing from proc metadata"
	grep -Fxq 'monitor_achieved_rates=456' "${run_path}/proc_pids" || fail "monitor pid missing from proc metadata"
	grep -Fxq 'monitor_achieved_rates_starttime=456456' "${run_path}/proc_pids" || fail "monitor starttime missing from proc metadata"

	observed=$(get_running_main_pid_for_run_path "${run_path}")
	assert_eq 123 "${observed}" "fake proc main pid detected"

	ok "atomic proc metadata with fake proc"
}

test_startup_lock_kernel_semantics()
{
	local tmp holder contender_status holder_status attempts

	command -v flock >/dev/null 2>&1 || fail "flock is required by the runtime"
	tmp=$(make_tmp_dir)

	(
		run_path="${tmp}/primary"
		acquire_startup_lock
		: > "${tmp}/ready"
		trap 'release_startup_lock; exit 0' TERM
		while :
		do
			:
		done
	) &
	holder=${!}
	for ((attempts=0; attempts<100; attempts++))
	do
		[[ -f ${tmp}/ready ]] && break
		sleep 0.01
	done
	[[ -f ${tmp}/ready ]] || fail "startup lock holder did not become ready"

	set +e
	(
		run_path="${tmp}/primary"
		acquire_startup_lock
	) >/dev/null 2>&1
	contender_status=${?}
	set -e
	[[ ${contender_status} -ne 0 ]] || fail "live startup lock was acquired by a contender"

	kill -TERM "${holder}"
	set +e
	wait "${holder}"
	holder_status=${?}
	set -e
	assert_eq 0 "${holder_status}" "startup lock holder exits zero on TERM"
	(
		run_path="${tmp}/primary"
		acquire_startup_lock
		release_startup_lock
	)

	ok "startup lock live holder and TERM release"
}

test_startup_lock_concurrency_and_sigkill_release()
{
	local tmp wins pid_a pid_b status_a status_b wins_count holder holder_status attempts

	tmp=$(make_tmp_dir)
	(
		run_path="${tmp}/primary"
		acquire_startup_lock
		printf 'a\n' >> "${tmp}/wins"
		while [[ ! -f ${tmp}/release ]]
		do
			:
		done
		release_startup_lock
	) &
	pid_a=${!}
	(
		run_path="${tmp}/primary"
		acquire_startup_lock
		printf 'b\n' >> "${tmp}/wins"
		while [[ ! -f ${tmp}/release ]]
		do
			:
		done
		release_startup_lock
	) &
	pid_b=${!}
	for ((attempts=0; attempts<100; attempts++))
	do
		[[ -f ${tmp}/wins ]] && break
		sleep 0.01
	done
	wins_count=$(wc -l < "${tmp}/wins" 2>/dev/null || printf 0)
	assert_eq 1 "${wins_count}" "exactly one concurrent flock contender wins"
	: > "${tmp}/release"
	set +e
	wait "${pid_a}"
	status_a=${?}
	wait "${pid_b}"
	status_b=${?}
	set -e
	[[ ${status_a} -ne ${status_b} ]] || fail "concurrent flock contenders should not have the same status"

	printf 'pid=999999\nstarttime=1\ntoken=obsolete\n' > "${tmp}/sigkill.startup.lock"
	(
		run_path="${tmp}/sigkill"
		acquire_startup_lock
		: > "${tmp}/sigkill-ready"
		while :
		do
			:
		done
	) &
	holder=${!}
	for ((attempts=0; attempts<100; attempts++))
	do
		[[ -f ${tmp}/sigkill-ready ]] && break
		sleep 0.01
	done
	[[ -f ${tmp}/sigkill-ready ]] || fail "SIGKILL lock holder did not become ready"
	kill -KILL "${holder}"
	set +e
	wait "${holder}" 2>/dev/null
	holder_status=${?}
	set -e
	[[ ${holder_status} -ne 0 ]] || fail "SIGKILL lock holder unexpectedly succeeded"
	(
		run_path="${tmp}/sigkill"
		acquire_startup_lock
		release_startup_lock
	) || fail "flock was not auto-released after SIGKILL"

	ok "startup lock concurrency, PID metadata independence, and SIGKILL release"
}

test_startup_lock_unsafe_path_fails_loud()
{
	local tmp run_path_for_test status

	tmp=$(make_tmp_dir)
	run_path_for_test="${tmp}/unsafe"
	ln -s "${tmp}/target" "${run_path_for_test}.startup.lock"
	set +e
	(
		run_path="${run_path_for_test}"
		acquire_startup_lock
	) >/dev/null 2>&1
	status=${?}
	set -e
	[[ ${status} -ne 0 ]] || fail "unsafe startup lock path was accepted"
	[[ -L ${run_path_for_test}.startup.lock ]] || fail "unsafe startup lock path was modified"

	ok "startup lock unsafe path fails loud"
}

test_runtime_path_safety()
{
	local tmp status

	tmp=$(make_tmp_dir)
	run_parent_path="${tmp}/run"
	run_path=
	unset instance_id

	assert_success "valid instance filename accepted" derive_instance_run_path "/tmp/config.primary-1.sh"
	assert_eq primary-1 "${instance_id}" "instance identifier derived from basename"
	assert_eq "${run_parent_path}/primary-1" "${run_path}" "runtime path derived as strict child"
	assert_success "derived runtime path accepted" runtime_path_is_safe
	assert_failure "empty instance rejected" derive_instance_run_path "/tmp/config..sh"
	assert_failure "nested instance rejected" derive_instance_run_path "/tmp/config.a/b.sh"
	assert_failure "suffix after config filename rejected" derive_instance_run_path "/tmp/config.primary.sh.extra"

	mkdir -p "${run_parent_path}"
	: > "${run_parent_path}/sentinel"
	run_path=${run_parent_path}
	instance_id=
	declare -gA proc_pids=() pinger_pids=()
	log_file_buffer_timeout_ms=0
	set +e
	(
		terminate() { :; }
		sleep_s() { :; }
		cleanup_and_killall 0
	)
	status=${?}
	set -e
	assert_eq 0 "${status}" "cleanup with unsafe parent exits cleanly"
	[[ -f ${run_parent_path}/sentinel ]] || fail "unsafe cleanup removed runtime parent"

	instance_id=primary
	run_path="${run_parent_path}/${instance_id}"
	mkdir "${run_path}"
	set +e
	(
		terminate() { :; }
		sleep_s() { :; }
		cleanup_and_killall 0
	)
	status=${?}
	set -e
	assert_eq 0 "${status}" "cleanup with safe child exits cleanly"
	[[ ! -e ${run_path} ]] || fail "safe instance runtime path was not removed"

	ok "runtime path safety"
}

test_operational_bounds()
{
	bufferbloat_detection_window=6
	bufferbloat_detection_thr=3
	reflector_misbehaving_detection_window=60
	reflector_misbehaving_detection_thr=3
	log_to_file=1
	log_file_buffer_size_B=512
	log_file_buffer_timeout_ms=500
	assert_success "default operational bounds accepted" validate_operational_bounds

	bufferbloat_detection_window=0
	assert_failure "zero bufferbloat window rejected" validate_operational_bounds
	bufferbloat_detection_window=6
	bufferbloat_detection_thr=0
	assert_failure "zero bufferbloat threshold rejected" validate_operational_bounds
	bufferbloat_detection_thr=7
	assert_failure "oversized bufferbloat threshold rejected" validate_operational_bounds
	bufferbloat_detection_thr=3

	reflector_misbehaving_detection_window=0
	assert_failure "zero reflector window rejected" validate_operational_bounds
	reflector_misbehaving_detection_window=60
	reflector_misbehaving_detection_thr=0
	assert_failure "zero reflector threshold rejected" validate_operational_bounds
	reflector_misbehaving_detection_thr=61
	assert_failure "oversized reflector threshold rejected" validate_operational_bounds
	reflector_misbehaving_detection_thr=3

	log_file_buffer_size_B=0
	assert_failure "zero log buffer size rejected" validate_operational_bounds
	log_file_buffer_size_B=512
	log_file_buffer_timeout_ms=0
	assert_failure "zero log buffer timeout rejected" validate_operational_bounds
	log_to_file=0
	assert_success "unused zero log timeout accepted" validate_operational_bounds

	ok "operational bounds"
}

test_stopped_pinger_metadata_is_cleared()
{
	local tmp fake_proc pinger_pid

	tmp=$(make_tmp_dir)
	run_path="${tmp}/run"
	mkdir "${run_path}"
	fake_proc="${tmp}/proc"
	write_fake_stat "${fake_proc}" 123 123123
	CAKE_AUTORATE_PROC_ROOT=${fake_proc}
	CAKE_AUTORATE_RUN_TOKEN=11111111-2222-3333-4444-555555555555
	export CAKE_AUTORATE_RUN_TOKEN
	sleep 30 &
	pinger_pid=${!}
	declare -gA proc_pids=([main]=123 [fping_pinger]="${pinger_pid}")
	declare -gA pinger_pids=([0]="${pinger_pid}")
	pingers_active=1
	pinger_method=fping

	assert_success "stopping fping succeeds" stop_pingers
	! kill -0 "${pinger_pid}" 2>/dev/null || fail "stopped pinger is still alive"
	assert_eq 0 "${#pinger_pids[@]}" "pinger pid map cleared"
	[[ -z ${proc_pids[fping_pinger]+set} ]] || fail "proc pid map retained stopped fping"
	grep -Fxq 'main=123' "${run_path}/proc_pids" || fail "main pid missing after pinger stop"
	! grep -q '_pinger=' "${run_path}/proc_pids" || fail "exported metadata retained stopped pinger"

	ok "stopped pinger metadata is cleared"
}

test_set_shaper_rate_with_fake_tc()
{
	local tmp fake_bin tc_log status saved_path

	tmp=$(make_tmp_dir)

	fake_bin="${tmp}/bin"
	mkdir "${fake_bin}"
	tc_log="${tmp}/tc.log"

	cat > "${fake_bin}/tc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ ${1-} == qdisc && ${2-} == show && ${3-} == root && ${4-} == dev ]]
then
	printf 'qdisc %s 8001: root refcnt 2 bandwidth 100Mbit\n' "${FAKE_TC_KIND:-cake}"
	exit "${FAKE_TC_SHOW_STATUS:-0}"
fi

if [[ ${1-} == qdisc && ${2-} == change && ${3-} == root && ${4-} == dev ]]
then
	printf '%s\n' "$*" >> "${FAKE_TC_LOG}"
	[[ ${6-} == "${FAKE_TC_EXPECT_KIND:-cake}" ]] || exit 7
	exit "${FAKE_TC_CHANGE_STATUS:-0}"
fi

printf 'unexpected tc invocation: %s\n' "$*" >&2
exit 99
EOF
	chmod +x "${fake_bin}/tc"

	saved_path=${PATH}
	PATH="${fake_bin}:${PATH}"
	FAKE_TC_LOG=${tc_log}
	FAKE_TC_KIND=cake_mq
	FAKE_TC_EXPECT_KIND=cake_mq
	FAKE_TC_CHANGE_STATUS=0
	FAKE_TC_SHOW_STATUS=0
	export PATH FAKE_TC_LOG FAKE_TC_KIND FAKE_TC_EXPECT_KIND FAKE_TC_CHANGE_STATUS FAKE_TC_SHOW_STATUS

	declare -gA shaper_rate_kbps last_shaper_rate_kbps interface qdisc_kind adjust_shaper_rate \
		compensated_avg_owd_delta_max_adjust_up_thr_us \
		compensated_owd_delta_delay_thr_us \
		compensated_avg_owd_delta_max_adjust_down_thr_us
	shaper_rate_kbps=([dl]=20000 [ul]=10000)
	last_shaper_rate_kbps=([dl]=10000 [ul]=10000)
	interface=([dl]=wan [ul]=ifb-wan)
	qdisc_kind=([dl]=cake [ul]=cake)
	adjust_shaper_rate=([dl]=1 [ul]=0)

	output_cake_changes=0
	dl_max_wire_packet_size_bits=12000
	ul_max_wire_packet_size_bits=12000
	dl_avg_owd_delta_max_adjust_up_thr_us=10000
	ul_avg_owd_delta_max_adjust_up_thr_us=10000
	dl_owd_delta_delay_thr_us=30000
	ul_owd_delta_delay_thr_us=30000
	dl_avg_owd_delta_max_adjust_down_thr_us=60000
	ul_avg_owd_delta_max_adjust_down_thr_us=60000
	max_wire_packet_rtt_us=0

	assert_success "cake_mq root qdisc detected" get_root_qdisc_kind dl
	assert_eq cake_mq "${qdisc_kind[dl]}" "detected qdisc kind"
	FAKE_TC_KIND=noqueue
	assert_failure "non-CAKE root qdisc rejected" get_root_qdisc_kind dl
	assert_eq cake_mq "${qdisc_kind[dl]}" "non-CAKE root qdisc preserves the last known kind"
	FAKE_TC_KIND=cake_mq
	assert_success "set shaper succeeds" set_shaper_rate dl
	assert_eq 20000 "${last_shaper_rate_kbps[dl]}" "last shaper updated after success"
	assert_eq 1800 "${max_wire_packet_rtt_us}" "successful shaper rate updates compensation"
	grep -Fxq 'qdisc change root dev wan cake_mq bandwidth 20000Kbit' "${tc_log}" || fail "tc change did not use detected cake_mq kind"

	FAKE_TC_CHANGE_STATUS=2
	FAKE_TC_SHOW_STATUS=1
	export FAKE_TC_CHANGE_STATUS
	shaper_rate_kbps[dl]=30000
	set +e
	set_shaper_rate dl
	status=${?}
	set -e
	assert_eq 2 "${status}" "tc failure status propagated"
	assert_eq 20000 "${last_shaper_rate_kbps[dl]}" "last shaper unchanged after failure"
	assert_eq 20000 "${shaper_rate_kbps[dl]}" "failed change re-anchors shaper_rate to the installed rate"
	assert_eq 1800 "${max_wire_packet_rtt_us}" "failed shaper rate preserves prior compensation"
	assert_eq cake_mq "${qdisc_kind[dl]}" "missing root qdisc preserves the last known kind"

	FAKE_TC_CHANGE_STATUS=0
	FAKE_TC_SHOW_STATUS=0
	export FAKE_TC_CHANGE_STATUS FAKE_TC_SHOW_STATUS
	assert_success "re-anchored rate is a no-op" set_shaper_rate dl
	assert_eq 20000 "${last_shaper_rate_kbps[dl]}" "no tc change until the controller sets a new rate"
	shaper_rate_kbps[dl]=30000
	assert_success "next controller rate is applied" set_shaper_rate dl
	assert_eq 30000 "${last_shaper_rate_kbps[dl]}" "last shaper updated after recovery"
	PATH=${saved_path}

	ok "set_shaper_rate with fake tc"
}

test_negative_cake_overhead()
{
	local tmp fake_bin expected observed saved_path

	tmp=$(make_tmp_dir)
	fake_bin="${tmp}/bin"
	mkdir "${fake_bin}"
	cat > "${fake_bin}/tc" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_TC_QDISC_OUTPUT}"
EOF
	chmod +x "${fake_bin}/tc"

	saved_path=${PATH}
	PATH="${fake_bin}:${PATH}"
	FAKE_TC_QDISC_OUTPUT='qdisc cake 1: root noatm overhead -8'
	export PATH FAKE_TC_QDISC_OUTPUT
	expected=$((8 * ($(< /sys/class/net/lo/mtu) - 8)))
	assert_success "negative CAKE overhead accepted" get_max_wire_packet_size_bits lo observed
	assert_eq "${expected}" "${observed}" "negative CAKE overhead compensation"

	FAKE_TC_QDISC_OUTPUT='qdisc cake 1: root raw'
	export FAKE_TC_QDISC_OUTPUT
	assert_failure "missing CAKE overhead rejected" get_max_wire_packet_size_bits lo observed
	PATH=${saved_path}

	ok "negative CAKE overhead"
}

test_terminate_reaps_child()
{
	local child

	sleep 30 &
	child=${!}

	terminate "${child}" 100
	! kill -0 "${child}" 2>/dev/null || fail "terminated child still exists"

	ok "terminate reaps child"
}

test_launcher_fail_fast()
{
	local tmp script_prefix config_prefix launcher status

	command -v timeout >/dev/null 2>&1 || {
		ok "launcher fail-fast skipped (timeout unavailable)"
		return
	}

	tmp=$(make_tmp_dir)

	script_prefix="${tmp}/script"
	config_prefix="${tmp}/config"
	mkdir "${script_prefix}" "${config_prefix}"
	launcher="${tmp}/launcher.sh"

	sed -e "s|%%SCRIPT_PREFIX%%|${script_prefix}|g" -e "s|%%CONFIG_PREFIX%%|${config_prefix}|g" \
		"${repo_dir}/launcher.sh.template" > "${launcher}"

	cat > "${script_prefix}/cake-autorate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case ${1} in
	*config.fast.sh)
		exit 23
		;;
	*)
		trap 'exit 0' TERM
		while :
		do
			sleep 1
		done
		;;
esac
EOF
	chmod +x "${script_prefix}/cake-autorate.sh" "${launcher}"
	: > "${config_prefix}/config.fast.sh"
	: > "${config_prefix}/config.slow.sh"

	set +e
	timeout 5s bash "${launcher}" >/dev/null 2>&1
	status=${?}
	set -e

	assert_eq 23 "${status}" "launcher exits with first failed child status"

	ok "launcher fail-fast"
}

test_launcher_child_success()
{
	local tmp script_prefix config_prefix launcher status

	tmp=$(make_tmp_dir)
	script_prefix="${tmp}/script"
	config_prefix="${tmp}/config"
	mkdir "${script_prefix}" "${config_prefix}"
	launcher="${tmp}/launcher.sh"

	sed -e "s|%%SCRIPT_PREFIX%%|${script_prefix}|g" -e "s|%%CONFIG_PREFIX%%|${config_prefix}|g" \
		"${repo_dir}/launcher.sh.template" > "${launcher}"

	cat > "${script_prefix}/cake-autorate.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod +x "${script_prefix}/cake-autorate.sh" "${launcher}"
	: > "${config_prefix}/config.primary.sh"

	set +e
	timeout 5s bash "${launcher}" >/dev/null 2>&1
	status=${?}
	set -e
	assert_eq 0 "${status}" "launcher exits zero when its child exits zero"

	ok "launcher child success"
}

test_launcher_operator_signal()
{
	local tmp script_prefix config_prefix launcher ready child_pid launcher_pid status attempt

	tmp=$(make_tmp_dir)
	script_prefix="${tmp}/script"
	config_prefix="${tmp}/config"
	mkdir "${script_prefix}" "${config_prefix}"
	launcher="${tmp}/launcher.sh"
	ready="${tmp}/ready"
	child_pid="${tmp}/child.pid"

	sed -e "s|%%SCRIPT_PREFIX%%|${script_prefix}|g" -e "s|%%CONFIG_PREFIX%%|${config_prefix}|g" \
		"${repo_dir}/launcher.sh.template" > "${launcher}"

	cat > "${script_prefix}/cake-autorate.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "${CAKE_AUTORATE_TEST_CHILD_PID}"
: > "${CAKE_AUTORATE_TEST_READY}"
trap 'exit 0' INT TERM
while :
do
	sleep 1
done
EOF
	chmod +x "${script_prefix}/cake-autorate.sh" "${launcher}"
	: > "${config_prefix}/config.primary.sh"

	CAKE_AUTORATE_TEST_READY=${ready} CAKE_AUTORATE_TEST_CHILD_PID=${child_pid} bash "${launcher}" >/dev/null 2>&1 &
	launcher_pid=${!}
	for ((attempt=0; attempt<100; attempt++))
	do
		[[ -f ${ready} ]] && break
		sleep 0.01
	done
	[[ -f ${ready} ]] || fail "launcher child did not become ready"

	kill -TERM "${launcher_pid}"
	set +e
	wait "${launcher_pid}"
	status=${?}
	set -e
	assert_eq 0 "${status}" "launcher exits zero on operator TERM"
	! kill -0 "$(< "${child_pid}")" 2>/dev/null || fail "launcher TERM left child running"

	ok "launcher operator signal cleanup"
}

test_numeric_validation
test_runtime_requires_flock
test_bash_requirement
test_pinger_field_validation
test_bytes_counter_validation
test_atomic_proc_metadata_with_fake_proc
test_startup_lock_kernel_semantics
test_startup_lock_concurrency_and_sigkill_release
test_startup_lock_unsafe_path_fails_loud
test_runtime_path_safety
test_operational_bounds
test_stopped_pinger_metadata_is_cleared
test_set_shaper_rate_with_fake_tc
test_negative_cake_overhead
test_terminate_reaps_child
test_launcher_fail_fast
test_launcher_child_success
test_launcher_operator_signal
