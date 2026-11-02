#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Resume safety and block topology without real devices.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$here/../lib.sh"
# shellcheck source=../../lastread
source "$here/../../lastread"
set +e
T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT
TMPD="$T/tmp" logs="$T/logs" map="$T/d.map" img="$T/d.img"
mkdir -p "$TMPD" "$logs"
mkmap "$map" <<'M'
0 512 +
512 512 ?
1024 512 +
1536 512 ?
M
refuse "map without image is refused" validate_image_map
truncate -s 1535 "$img"
refuse "image shorter than last rescued block is refused" validate_image_map
truncate -s 1536 "$img"
check "image may end at last rescued block" validate_image_map
truncate -s 2048 "$img"
check "full-length image is accepted" validate_image_map
printf 'size=2048\nsector=512\nstart=1\nwwn=id-a\nserial=abc\n' >"$T/old"
cp "$T/old" "$T/new"
check "matching identity accepted" identity_check "$T/old" "$T/new"
sed -i 's/wwn=id-a/wwn=id-b/' "$T/new"
refuse "changed WWN refused" identity_check "$T/old" "$T/new"
sed -i 's/wwn=id-b/wwn=/' "$T/new"
refuse "missing recorded WWN refused" identity_check "$T/old" "$T/new"
cp "$T/old" "$T/new"
sed -i 's/start=1/start=2/' "$T/new"
refuse "equal-sized different partition refused" identity_check "$T/old" "$T/new"
source_identity() { cat "$T/new"; }
cp "$T/old" "$logs/source.identity"
accept_source_change=0
refuse "changed identity needs explicit adoption" identity_prepare
accept_source_change=1
check "changed identity can be explicitly adopted" identity_prepare
(
  sleep() { :; }
  rescan_host() { return 0; }
  resolve_device() { :; }
  blockdev() { echo 2048; }
  source_identity() { cat "$T/new"; }
  device_ok() { touch "$T/read-after-mismatch"; }
  SCSI_HOST=host3 TRANSPORT=sata rescan=1 recoveries=0 rescan_attempts=1 rescan_pause=0
  cp "$T/old" "$TMPD/source.identity"
  recover_device >"$T/reconnect.out" 2>&1
)
eq "reconnected mismatched device is rejected" 1 "$?"
check "reconnection error identifies the mismatch" contains "$(cat "$T/reconnect.out")" "returned device identity does not match"
check "reconnected mismatched device stops before probing" test ! -e "$T/read-after-mismatch"
# Stub two branching ancestry trees as returned by lsblk -s.
lsblk() {
  if [[ $* == *MAJ:MIN,NAME* ]]; then
    printf '253:1 /dev/target1\n253:2 /dev/target2\n'
    return
  fi
  case ${*: -1} in
    /dev/source) printf '253:0\n8:0\n8:16\n' ;;
    /dev/target1) printf '253:1\n8:16\n8:32\n' ;;
    /dev/target2) printf '253:2\n8:48\n' ;;
    *) return 1 ;;
  esac
}
findmnt() {
  case $* in
    *FSTYPE*) printf '%s\n' "${TEST_FSTYPE:-ext4}" ;;
    *shared*) echo 253:1 ;;
    *separate*) echo 253:2 ;;
    *) return 1 ;;
  esac
}
dev=/dev/source
refuse "shared ancestor in a multi-device chain is refused" check_destination shared
check "different ancestry is accepted" check_destination separate
out="$(check_destination unknown 2>&1)"
check "unknown topology warns" contains "$out" "cannot determine"
out="$(TEST_FSTYPE=btrfs check_destination separate 2>&1)"
check "multi-device filesystem warns" contains "$out" "cannot verify every member"
finish
