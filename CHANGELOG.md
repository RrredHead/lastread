# Changelog

## 0.1.0 — unreleased

First version. Released under GPL-3.0-or-later.

### What it does

- Images a block device or partition with GNU ddrescue in phases (copy, scrape, retry, zones, report, extract) that
  are derived from the ddrescue map, so that any stop is followed by a plain re-run.
- Watches the disk temperature (`smartctl`, or `--temp-cmd`) and stops ddrescue at `--stop`, resuming at `--resume`.
- Detects a dropped disk, stops ddrescue before it marks the rest as bad, reverts the traces, and brings the disk
  back by rescanning its SCSI host (SATA/SAS); explains why it cannot on other transports.
- Defers zones where the disk hangs, reads everything else first and the zones last, from both ends, down to
  unreadable cores (`--give-up-zones`, `--add-zone`).
- NTFS file level without mounting (The Sleuth Kit): lists of intact and damaged files, an inventory without the disk,
  targeted recovery (`--file`, `--pick`), extraction (`--extract-to`, `--include`, `--map`, `--owner`), a workaround for
  the `$ATTRIBUTE_LIST` stitching error of The Sleuth Kit 4.12, and detection of silent garbage.

- `--triage`: a read-only check of a disk before a rescue (SMART, kernel messages, nine sample reads) with a
  verdict and suggested options.
- `--status` (and `--json`): progress of a rescue from its map and logs, without touching the disk.
- `--on-event PROGRAM` and `--print-service`: notifications, and a systemd unit that continues a rescue after a
  power cycle. A new exit status 3 says that the disk needs a power cycle.
- The source gets the kernel's read-only flag while rescuing (`--no-readonly` to leave it alone).
- The file level works on a partition of a whole-disk image (`mmls`, `--partition N`), also with 4096-byte sectors.
- The file level reads ext2/3/4 (extents, holes, inline data), FAT12/16/32 and exFAT as well as NTFS. FAT and exFAT
  are recognised from the boot sector, because `fsstat` of The Sleuth Kit 4.12 does not return on exFAT.
- `--verify`: extracted files are checked by SHA-256 after a sync and a cache drop; a manifest in `sha256sum -c`
  format; files already in place are checked too.
- `--recheck-garbage`: the image is scanned for the suspect pattern, the sectors are marked bad and read again,
  what stays garbage counts as unreadable.
- A metadata-first phase for NTFS (`$MFT`, directory indexes) and `--first PATH`; `--no-meta-first` to skip it.

### Behaviour worth knowing

- The kernel command timeout is only raised to `--kernel-timeout`, never lowered.
- The disk not answering and needing a power cycle is exit status 3 (it was 1).
- On NTFS a rescue starts with the metadata-first phase. It reads the structures of the volume before the bulk, so
  the order in which areas are read differs from a plain ddrescue run; use `--no-meta-first` for the plain order.
- `--extract` extracts **intact** files only, in a normal run as well as after `--inventory` and in targeted recovery.
  `--extract-damaged` (normal run only) also extracts damaged files, their unreadable parts as zeros.
- Directory entries that point to MFT entries that are readable and not in use (stale index records of deleted
  files) are not listed as files; an entry that cannot be read is kept and reported as unknown. Allocated entries that
  the directory walk does not reach are still listed, as `?/NAME`, and count as incomplete; such unknown rows are never
  extracted.
- A file level that is impossible because The Sleuth Kit is missing makes `--extract`, `--inventory`, `--pick` and `--file`
  refuse to start; in a plain run it is reported as pending and not recorded as done. An image without a file level
  (not NTFS, a partition table, `--no-fs`) is skipped with a message in a plain run; `--inventory` and `--pick`/`--file`
  fail with it.
- After a targeted recovery (`--file`, `--pick`) the earlier report and extraction are invalidated, so that the next
  normal run classifies the files again.
- `--name` is required when SOURCE is not under `/dev/disk/` or `/dev/mapper/` (the device name can change).
- `--suspect-pattern` / `--suspect-zeros` are validated as a `grep -P` pattern before anything is read.
- `--rescan-attempts 0` means `--no-rescan`; numbers with a leading zero are decimal.
- `--map SRC:DST` also accepts a single file as SRC; `--include`/`--map` with `--inventory` print counts; without them
  the inventory prints counts per top-level directory. Without filters `--extract` extracts the whole volume, system
  folders included.
- The earlier copy of the map is kept as `.before-revert.prev` when a second revert happens.
- The zero-run check flags any file with a run of zeros of `--suspect-zeros` (128 KiB) — including sparse files.
  Raise or disable it for such data.
- `LC_ALL=C` is set by the script: all parsed output is locale independent.
- The sector size of the device (`blockdev --getss`) is passed to ddrescue (`-b`) and used to align zones (4Kn works).
- smartctl's exit status (a bit mask that also describes the health of the disk) is ignored; the JSON decides.
- The run lock is not inherited by child processes, so a run can start right after another has been interrupted.
- The image directory **and** the extraction directory must not be on the failing disk; mounted partitions of the
  source disk are refused too.
- `--dry-run` also works with `--inventory`; `--inventory` and extraction from an image need no root unless the owner
  of the extracted files is another user.
- Messages show sizes below 100 MB in MB.

### Not included

No repair of the disk, no writing to the source, no GUI, no Windows or macOS support; no file level for file systems
other than NTFS, ext2/3/4, FAT and exFAT; no metadata-first phase except for NTFS; no USB reset.
