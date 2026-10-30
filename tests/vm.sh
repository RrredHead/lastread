#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs the tests inside a Multipass VM, so that nothing touches the host's disks.
#   tests/vm.sh create                 create the VM and install the dependencies
#   tests/vm.sh sync                   copy the working tree into the VM (~/lastread)
#   tests/vm.sh unit                   sync, then run the unit tests in the VM
#   tests/vm.sh integration [TEST...]  sync, then run the integration tests as root in the VM
#   tests/vm.sh shell                  open a shell in the VM
#   tests/vm.sh delete                 delete the VM
# The VM name comes from $VM_NAME (default: rescue-test).
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM="${VM_NAME:-rescue-test}"
REMOTE=/home/ubuntu/lastread # the default user of a Multipass Ubuntu VM

vm() { multipass exec "$VM" -- "$@"; }

cmd_create() {
  multipass launch 24.04 --name "$VM" --cpus 2 --memory 4G --disk 24G
  # linux-modules-extra provides scsi_debug.
  # shellcheck disable=SC2016 # the script is expanded by the shell inside the VM
  vm sudo bash -c 'export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq gddrescue smartmontools jq sleuthkit ntfs-3g whiptail dmsetup util-linux \
      e2fsprogs attr exfatprogs dosfstools "linux-modules-extra-$(uname -r)"'
}
cmd_sync() {
  tar --exclude=.git -C "$ROOT" -cf - . |
    vm bash -c "rm -rf '$REMOTE' && mkdir -p '$REMOTE' && tar -xf - -C '$REMOTE'"
}
cmd_unit() {
  cmd_sync
  vm bash -c "cd '$REMOTE' && tests/unit/run.sh"
}
cmd_integration() {
  cmd_sync
  vm sudo bash -c "cd '$REMOTE' && tests/integration/run.sh \"\$@\"" _ "$@"
}

case ${1:-} in
  create) cmd_create ;;
  sync) cmd_sync ;;
  unit) cmd_unit ;;
  integration)
    shift
    cmd_integration "$@"
    ;;
  shell) multipass shell "$VM" ;;
  delete)
    multipass delete --purge "$VM"
    ;;
  *)
    sed -n '2,10p' "${BASH_SOURCE[0]}"
    exit 1
    ;;
esac
