# Feature matrix

Every feature, the code that implements it (function names in `lastread`) and the tests that check it.
`U:` = `tests/unit/`, `I:` = `tests/integration/` (run as root in a VM: `tests/vm.sh integration`).

## Imaging and orchestration

| Feature | Code | Tests |
| --- | --- | --- |
| Phase chosen from the ddrescue map: copy → scrape → retry → zones → report → extract; any stop is followed by a plain re-run | `next_phase`, `has`, main loop | U: `test_map` (phase selection, zones, abandoned zones); I: `test_dm_phases` (all phases, no-op second run, interruption and resume) |
| Copy phase always restarts from pass 1 at the current position | `run_ddrescue` (copy), `set_map_pos`, `map_pos` | U: `test_map` (status line `pos ? 1`); I: `test_hang_zones`, `test_dm_phases` (resume) |
| `--min-rate` / `--skip-size` / `--reverse` / `--start-at` (first run only) | `run_ddrescue`, `validate_args` | U: `test_args`; I: `test_dm_phases` (ddrescue arguments, `--start-at` announced, image correct) |
| `--retries N` for the retry phase | `run_ddrescue` (retry) | I: `test_dm_phases` |
| Safety stop: a phase three times in a row without progress | main loop (`stalls`) | I: `test_safety` (stalling ddrescue) |
| Safety stop: ddrescue failing five times in a row without progress | main loop (`fails`) | I: `test_safety` (failing ddrescue) |
| Sector size from the device (`blockdev --getss`), passed as `-b`; zones aligned to it (4Kn) | `resolve_device`, `run_ddrescue`, `zone_put` | U: `test_zones` (4096 alignment); I: `test_scsi_debug` (4Kn disk) |
| Any device and any file system can be imaged; `--no-fs` | `image_prepare`, `report` | I: `test_dm_phases` (`--no-fs`), `test_ntfs` (ext4, partition table) |

## Watchdog

| Feature | Code | Tests |
| --- | --- | --- |
| Temperature every `--interval`; stop at `--stop` (SIGTERM, map saved), continue at `--resume`, hysteresis required | `run_ddrescue`, `wait_cool`, `validate_args` | U: `test_args` (`--resume` below `--stop`); I: `test_watchdog` (stop, hysteresis at 47 °C, resume at 44 °C) |
| smartctl + jq source; exit-status mask ignored; `-d sat` fallback / `--smart-type` | `temperature`, `detect_temperature_source` | U: `test_watchdog` (stub smartctl) |
| `--temp-cmd` / `$LASTREAD_TEMP_CMD`; `--no-temp`; no source = unwatched with a warning | `temperature`, `detect_temperature_source` | U: `test_watchdog`; I: `test_watchdog` (failing sensor, `--no-temp`) |
| Device check together with temperature: sysfs state and one direct read | `device_ok` | I: `test_scsi_debug`, `test_hang_zones` |
| Kernel command timeout 180 s while rescuing, restored on exit | `main` (`orig_timeout`), `cleanup`, `recover_device` | I: `test_scsi_debug` |
| `systemd-inhibit` while running (if available) | `main` | I: `test_dm_phases` |
| `flock` against a second run | `main` (fd 8) | I: `test_safety` |
| Checks: source not mounted, image directory not on the same disk, enough room | `preflight_device` | I: `test_dm_phases` (mounted), `test_safety` (same disk, no room) |
| `--dry-run` | `main` | I: `test_dm_phases`, `test_safety` |
| Logs: run log, ddrescue events and rates, ddrescue output per phase | `note`, `run_ddrescue` | I: `test_dm_phases` |

## Dropped disk

| Feature | Code | Tests |
| --- | --- | --- |
| ddrescue is stopped at once when the disk drops (SIGTERM) | `run_ddrescue` (exit 11) | I: `test_hang_zones`, `test_scsi_debug` |
| Traces (`*`, `/`, `-` larger than `--artifact-bad`; total above `--artifact-limit`) return to `?`; a copy of the map is kept | `artifact_bytes`, `revert_artifacts` | U: `test_map`; I: `test_hang_zones` (revert after each drop), `test_safety` (traces found at the start) |
| Return without a power cycle: pause, `- - -` into the host scan, wait for the device, re-resolve the name | `recover_device`, `rescan_host`, `resolve_device` | I: `test_scsi_debug` (drop in the middle of a read, image equals the disk) |
| At most `--rescan-attempts` returns in a row without progress, then a power cycle | `recover_device`, `die_device` | U: `test_watchdog` (counter); I: `test_scsi_debug` (`--no-rescan`) |
| The SCSI host is remembered and rescanned at the next start | `main`, `logs/scsi-host` | I: `test_scsi_debug` (disk missing at the start) |
| Transports without a host rescan (USB, NVMe) are detected and explained | `rescan_unavailable_reason` | U: `test_watchdog` |

## Deferred zones

| Feature | Code | Tests |
| --- | --- | --- |
| Hang position from the rate log (last non-zero rate), ±`--zone-margin` zone, zones merge | `hang_position`, `zone_hang`, `zone_put` | U: `test_map`, `test_zones`; I: `test_hang_zones` |
| Everything outside the zones is read first (ddrescue domain) | `write_domain`, `has` | U: `test_map` (domains); I: `test_hang_zones` |
| Zones last, one by one, alternately from the start and the end | `zone_next`, `run_ddrescue` (zones) | I: `test_hang_zones` (f → r → f → r) |
| A hang narrows the zone by exactly what the map shows as rescued; bad sectors at the edge do not block | `unrescued_span`, `zone_hang` | U: `test_map`, `test_zones` |
| Two attempts in a row with less than `--zone-min-progress` = a core; exit status 2 when only cores remain | `zone_hang`, `zone_next`, `zones-stuck` | U: `test_zones`; I: `test_hang_zones` |
| `--give-up-zones`: files in cores are reported as damaged | `main`, `report` | I: `test_hang_zones` |
| `--add-zone FROM-TO`, once only | `main`, `zones.added` | I: `test_hang_zones` |
| Zones covering the whole device: nothing outside, no endless loop | `has` | U: `test_map` |
| A message printed while the zone list is rewritten must not corrupt it | `zone_hang` | U: `test_zones` (fully read zone) |

## File level

| Feature | Code | Tests |
| --- | --- | --- |
| Parsing with The Sleuth Kit, no mounting; file system detected with `fsstat`; not NTFS → skipped with a message; `--no-fs` | `image_prepare` | I: `test_ntfs` (NTFS, ext4, partition table) |
| Image shorter than the partition is extended sparsely before parsing | `image_prepare` | I: `test_ntfs` (short image) |
| File list with full paths; system files and streams skipped; stale index entries dropped (verified with `istat`, unreadable entries kept) | `tsk_files` | U: `test_tsk` |
| Allocated entries missing from the walk are listed as `?/NAME` and count as incomplete | `tsk_files`, `classify` | U: `test_tsk` |
| Classification `intact` / `damaged` / `unknown` by the map | `classify`, `merge_ranges` | U: `test_tsk` |
| `$ATTRIBUTE_LIST` workaround: pieces from their own entries, within the range by the list, sizes from VCN 0, holes and overlaps → `broken` | `file_map` | U: `test_tsk` (real output, middle chunk under another id, shifted stitching, holes, overlaps, sparse, resident, compressed); I: `test_ntfs` (fragmented files with lists, byte-for-byte) |
| Copy by pieces (`dd`); `icat` only for resident and compressed | `file_stream` | U: `test_tsk`; I: `test_ntfs` |
| `--inventory`: lists of whole and incomplete files from the image, any stage; with `--extract` only the whole ones | `inventory_run` | I: `test_ntfs` |
| `--file PART` (no questions) and `--pick` (window, plain questions) | `targeted_run`, `ui_checklist`, `write_ranges_domain`, `has_in` | U: `test_map` (domains); I: `test_ntfs` (`--file`, `--pick` through a pty) |
| Extraction: `.part` + rename, size check, time from the volume, skip if present with the same size and time | `extract_files` | U: `test_tsk`; I: `test_ntfs` |
| `--extract-to`, `--include`, `--map`, `--owner`, modes | `dest_for`, `setup_owner`, `make_dirs` | U: `test_args`, `test_tsk`, `test_watchdog`; I: `test_ntfs` |
| Intact files only by default; `--extract-damaged` | `extract`, `extract_files` | U: `test_args`; I: `test_ntfs` |
| Silent garbage: pattern, zero threshold, list of suspicious files | `validate_args` (pattern), `extract_files` | U: `test_args`, `test_suspect`, `test_tsk`; I: `test_ntfs` |

## Lessons kept in the code

| Lesson | Where | Tests |
| --- | --- | --- |
| Paths and keys go to awk through `ENVIRON`, not `-v` | `classify`, `tsk_files`, `targeted_run` | U: `test_tsk` (backslashes in paths) |
| `pgrep -x` plus an argument check, never `pgrep -f` | `preflight_device` | I: `test_safety` |
| A running script is replaced only through a new file and `mv` | README, docs | — (documentation) |
| ddrescue's rate log is written on exit | `hang_position` callers | I: `test_hang_zones` |
| `LC_ALL=C` for parsing | top of the script | U: `test_watchdog` |
| Image extended with `truncate` before TSK | `image_prepare` | I: `test_ntfs` |
| Size and time do not catch a cut-short write | `extract_files`, README | — (documentation) |
| The run lock is not inherited by children | `run_ddrescue`, `main` | I: `test_dm_phases` (re-run right after an interruption) |
