#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# A real SCSI disk (the scsi_debug module): it is deleted in the middle of a read and brought back
# by rescanning its SCSI host; the image equals the disk. Also: the kernel command timeout while
# rescuing and its restoration, a disk that is missing at the start, a 4096-byte-sector disk.
# Skipped when the scsi_debug module is not available (it is in linux-modules-extra on Ubuntu).
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$here/../lib.sh"
# shellcheck source=lib.sh
source "$here/lib.sh"
it_init
set +e
trap 'it_cleanup; rmmod scsi_debug 2>/dev/null' EXIT

if ! modprobe -n scsi_debug 2>/dev/null; then
  skip "scsi_debug is not available on this kernel"
  finish
  exit 0
fi

sd_name() { # the kernel name of the scsi_debug disk
  local p
  for p in /sys/bus/pseudo/drivers/scsi_debug/adapter*/host*/target*/*/block/*; do
    if [[ -e $p ]]; then
      basename "$p"
      return 0
    fi
  done
  return 1
}
sd_byid() { # the stable by-id path of /dev/NAME
  local l
  for l in /dev/disk/by-id/scsi-3*; do
    if [[ $(readlink -f "$l") == "/dev/$1" ]]; then
      printf '%s' "$l"
      return 0
    fi
  done
  return 1
}
load_disk() { # load_disk SIZE_MB SECTOR_SIZE: loads scsi_debug and sets SD, BYID
  rmmod scsi_debug 2>/dev/null
  modprobe scsi_debug dev_size_mb="$1" sector_size="$2" delay=2 ndelay=0 num_tgts=1 max_luns=1 || return 1
  udevadm settle -t 20
  local tries
  for tries in $(seq 1 30); do
    : "$tries"
    SD="$(sd_name)"
    [[ -n $SD ]] && BYID="$(sd_byid "$SD")" && return 0
    sleep 1
  done
  return 1
}

# === 512-byte sectors: a drop in the middle of the copy =================================================
SIZE_MB=96
load_disk $SIZE_MB 512 || {
  fail "scsi_debug disk did not appear"
  finish
  exit 1
}
src="$(make_backing src $((SIZE_MB * M)))"
dd if="$src" of="/dev/$SD" bs=1M oflag=direct status=none
D="$W/out"
mkdir -p "$D"
host="$(readlink -f "/sys/block/$SD/device" | grep -o 'host[0-9]*' | tail -1)"
check "the test disk has a SCSI host" test -n "$host"
orig_timeout="$(cat "/sys/block/$SD/device/timeout")"

(
  # during the run: the kernel timeout must be 180; then drop the disk
  sleep 2
  cat "/sys/block/$SD/device/timeout" >"$W/timeout-during"
  sleep 1
  echo 1 >"/sys/block/$SD/device/delete"
) &
IT_BG+=("$!")
tool "$BYID" --dir "$D" --name drop --interval 1 --no-temp --no-fs --rescan-pause 2
rc_is "the run with a dropped disk finishes" 0
check "the drop was noticed" out_has "the disk dropped"
check "the traces were reverted" out_has "returned to \"not tried\""
check "the disk was brought back by rescanning its host" out_has "rescanning $host"
check "the disk is back" out_has "the disk is back"
check "the image equals the disk" same_bytes "$src" "$D/drop.img" 0 $((SIZE_MB * M))
eq "the kernel timeout was 180 while rescuing" 180 "$(cat "$W/timeout-during")"
new_sd="$(sd_name)"
eq "the kernel timeout is restored afterwards" "$orig_timeout" "$(cat "/sys/block/$new_sd/device/timeout")"
eq "the SCSI host is remembered in the logs" "$host" "$(cat "$D/drop.logs/scsi-host")"
check "a hang position was turned into a deferred zone" grep -F "deferred zones" "$D/drop.logs/rescue.log"

# === the disk is missing at the start: the remembered host is rescanned ===================================
D2="$W/out2"
mkdir -p "$D2"
"$TOOL" "$BYID" --dir "$D2" --name missing --interval 1 --no-temp --no-fs >"$W/missing1.out" 2>&1 &
pid=$!
sleep 3
kill -TERM "$pid"
wait "$pid"
eq "the first run is interrupted" 130 "$?"
echo 1 >"/sys/block/$(sd_name)/device/delete"
sleep 1
check "the disk is gone" test ! -b "$BYID"
tool "$BYID" --dir "$D2" --name missing --interval 1 --no-temp --no-fs
rc_is "a run without the disk rescans the remembered host and finishes" 0
check "...and says so" out_has "the disk is missing — rescanning $host"
check "...the image equals the disk" same_bytes "$src" "$D2/missing.img" 0 $((SIZE_MB * M))

# === --no-rescan: a dropped disk means a power cycle ============================================================
D3="$W/out3"
mkdir -p "$D3"
(
  sleep 3
  echo 1 >"/sys/block/$(sd_name)/device/delete"
) &
IT_BG+=("$!")
tool "$BYID" --dir "$D3" --name norescan --interval 1 --no-temp --no-fs --no-rescan
rc_is "--no-rescan: the run stops" 1
check "...asks for a power cycle" out_has "Power the machine fully off"
check "...and says rescanning is off" out_has "rescanning is off"
# bring it back for the next scenario and finish the image
echo "- - -" >"/sys/class/scsi_host/$host/scan"
udevadm settle -t 20
sleep 2
tool "$BYID" --dir "$D3" --name norescan --interval 1 --no-temp --no-fs --no-rescan
rc_is "after the disk is back, the same command finishes the image" 0
check "...and the image equals the disk" same_bytes "$src" "$D3/norescan.img" 0 $((SIZE_MB * M))

# === 4096-byte logical sectors ========================================================================================
load_disk 64 4096 || {
  fail "4Kn scsi_debug disk did not appear"
  finish
  exit 1
}
src4="$(make_backing src4 $((64 * M)))"
dd if="$src4" of="/dev/$SD" bs=4096 oflag=direct status=none
eq "the test disk has 4096-byte logical sectors" 4096 "$(blockdev --getss "/dev/$SD")"
D4="$W/out4"
mkdir -p "$D4"
tool "$BYID" --dir "$D4" --name k4 --interval 1 --no-temp --no-fs --add-zone 20000000-24000001
rc_is "a 4Kn disk is imaged" 0
check "the sector size is passed to ddrescue" out_has "-b 4096"
check "the image equals the disk" same_bytes "$src4" "$D4/k4.img" 0 $((64 * M))
check "a manual zone that is not sector-aligned works on 4Kn (it is aligned by the tool)" out_has "deferred by hand"

finish
