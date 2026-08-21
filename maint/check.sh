#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

command -v shellcheck >/dev/null 2>&1 || {
	printf >&2 '%s\n' 'maint/check.sh: shellcheck is required'
	exit 1
}
cd "${repo_dir}"

bash_scripts=(
	bench_cpu.sh
	cake-autorate.sh
	config.primary.sh
	defaults.sh
	launcher.sh.template
	lib.sh
	maint/update_setupsh_branch.sh
	maint/version_bump.sh
	mqtt-config.sh.example
	mqtt-publisher.sh
	sqm-setup.sh
	tests/regression.sh
)
sh_scripts=(
	cake-autorate.template
	maint/mdformat.sh
	mqtt-publisher.template
	setup.sh
	uninstall.sh
)

for ((i=0; i<${#bash_scripts[@]}; i++))
do
	bash_scripts[i]="${repo_dir}/${bash_scripts[i]}"
done
for ((i=0; i<${#sh_scripts[@]}; i++))
do
	sh_scripts[i]="${repo_dir}/${sh_scripts[i]}"
done

printf '%s\n' 'Checking shell syntax...'
bash -n "${bash_scripts[@]}"
sh -n "${sh_scripts[@]}"

printf '%s\n' 'Running ShellCheck...'
shellcheck "${bash_scripts[@]}" "${sh_scripts[@]}"

printf '%s\n' 'Running regression tests...'
bash "${repo_dir}/tests/regression.sh"
