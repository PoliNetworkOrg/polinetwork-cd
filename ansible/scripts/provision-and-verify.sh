#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
ansible_dir="$(cd -- "${script_dir}/.." && pwd)"
readonly ansible_dir
readonly inventory="${1:-inventories/production/hosts.yml}"
readonly artifact_dir="${ANSIBLE_ARTIFACT_DIR:-${ansible_dir}/artifacts}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
readonly timestamp

mkdir -p -- "$artifact_dir"
cd -- "$ansible_dir"

ansible-playbook --inventory "$inventory" playbooks/provision.yml --check --diff \
  | tee "${artifact_dir}/${timestamp}-check.log"

ansible-playbook --inventory "$inventory" playbooks/provision.yml \
  | tee "${artifact_dir}/${timestamp}-apply-first.log"

ANSIBLE_NOCOLOR=1 ansible-playbook --inventory "$inventory" playbooks/provision.yml \
  | tee "${artifact_dir}/${timestamp}-apply-second.log"

recap="$(grep -E '^k3s01[[:space:]]+:' "${artifact_dir}/${timestamp}-apply-second.log" | tail --lines=1)"
if [[ ! "$recap" =~ changed=0 ]] || [[ ! "$recap" =~ unreachable=0 ]] || [[ ! "$recap" =~ failed=0 ]]; then
    printf 'Second provision run was not idempotent or successful: %s\n' "$recap" >&2
    exit 1
fi

ansible-playbook --inventory "$inventory" playbooks/verify.yml \
  | tee "${artifact_dir}/${timestamp}-verify.log"
