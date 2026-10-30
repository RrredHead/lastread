#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# --triage: sample positions, SMART findings from smartctl JSON, the classification of sample reads.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$here/../lib.sh"
# shellcheck source=../../lastread
source "$here/../../lastread"
set +e

T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT
M=1048576

# --- sample positions
eq "positions for 32 MiB: nine, the last one is the final MiB" "0 4194304 8388608 12582912 16777216 20971520 25165824 29360128 32505856" "$(triage_positions $((32 * M)) | paste -sd' ')"
eq "positions for a 1 MiB device" "0" "$(triage_positions $M | paste -sd' ')"
eq "positions for a device smaller than 1 MiB" "" "$(triage_positions 4096 | paste -sd' ')"
eq "positions are multiples of 1 MiB" 0 "$(triage_positions $((1000 * M + 12345)) | awk -v m=$M '$1 % m != 0 {bad++} END {print bad + 0}')"

# --- SMART findings (JSON as smartctl -j prints it)
reset() { TRI_NOTES=() TRI_WARN=() TRI_RED=(); }
healthy='{"model_name":"EXAMPLE DISK","smart_status":{"passed":true},"power_on_time":{"hours":1200},"temperature":{"current":35},"ata_smart_attributes":{"table":[{"id":5,"name":"Reallocated_Sector_Ct","raw":{"value":0}},{"id":197,"name":"Current_Pending_Sector","raw":{"value":0}},{"id":198,"name":"Offline_Uncorrectable","raw":{"value":0}},{"id":199,"name":"UDMA_CRC_Error_Count","raw":{"value":0}}]}}'
reset
out="$(triage_smart_json "$healthy")"
triage_smart_json "$healthy" >/dev/null
check "a healthy disk: facts are printed" contains "$out" "SMART health:   passed"
eq "a healthy disk: no findings" 0 "$((${#TRI_WARN[@]} + ${#TRI_RED[@]}))"
worn='{"model_name":"EXAMPLE DISK","smart_status":{"passed":false},"ata_smart_attributes":{"table":[{"id":5,"raw":{"value":24}},{"id":187,"raw":{"value":3}},{"id":197,"raw":{"value":8}},{"id":198,"raw":{"value":8}},{"id":199,"raw":{"value":12}}]}}'
reset
triage_smart_json "$worn" >/dev/null
joined="${TRI_WARN[*]}"
check "worn: SMART FAILED is a warning" contains "$joined" "overall health is FAILED"
check "worn: pending sectors" contains "$joined" "8 sectors are pending"
check "worn: offline-uncorrectable sectors" contains "$joined" "8 sectors are offline-uncorrectable"
check "worn: reported uncorrectable errors" contains "$joined" "3 uncorrectable read errors"
check "worn: CRC errors point at the cable" contains "$joined" "12 interface CRC errors"
check "worn: a few reallocated sectors are only a note" contains "${TRI_NOTES[*]}" "24 reallocated sectors"
reset
triage_smart_json '{"ata_smart_attributes":{"table":[{"id":5,"raw":{"value":2500}}]}}' >/dev/null
check "many reallocated sectors: heavy wear" contains "${TRI_WARN[*]}" "2500 reallocated sectors: the surface is heavily worn"
reset
triage_smart_json '{"model_name":"EXAMPLE NVME","smart_status":{"passed":true},"nvme_smart_health_information_log":{"critical_warning":0,"media_errors":3,"percentage_used":12,"available_spare":100}}' >/dev/null
check "NVMe media errors" contains "${TRI_WARN[*]}" "NVMe reports 3 media errors"
reset
triage_smart_json '{"model_name":"EXAMPLE NVME","nvme_smart_health_information_log":{"critical_warning":4,"media_errors":0,"percentage_used":3,"available_spare":100}}' >/dev/null
check "NVMe critical warning" contains "${TRI_WARN[*]}" "critical warning flags are set (4)"
reset
out="$(triage_smart_json '{"model_name":"X"}')"
check "no SMART status: said so" contains "$out" "SMART health:   not reported"

# --- classification of a sample read (dd is replaced by a shim)
mkdir -p "$T/bin"
cat >"$T/bin/dd" <<'S'
#!/bin/sh
case "$SHIM" in
  ok) exit 0 ;;
  slow) sleep 1.3; exit 0 ;;
  error) exit 1 ;;
  hang) exec sleep 30 ;;
esac
S
chmod +x "$T/bin/dd"
PATH="$T/bin:$PATH"
dev=/dev/null triage_timeout=1
SHIM=ok triage_read 0
eq "a quick read is ok" ok "$TRI_RES"
triage_timeout=3
SHIM=slow triage_read 0
triage_timeout=1
eq "a read of more than a second is slow" slow "$TRI_RES"
SHIM=error triage_read 0
eq "a failing read is an error" error "$TRI_RES"
start=$SECONDS
SHIM=hang triage_read 0
eq "a hung read is abandoned as a timeout" timeout "$TRI_RES"
check "...after the limit, not after the hang" test $((SECONDS - start)) -le 3

finish
