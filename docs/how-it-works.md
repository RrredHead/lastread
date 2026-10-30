# How lastread works

This document explains the parts that look odd. Almost every one of them is a fix for something that went wrong on a
real failing drive, and the tests keep them from being "simplified" back.

## The loop

The whole state is on disk: the ddrescue map (`NAME.map`) and a few files in `NAME.logs/`. Each time through the
loop the tool derives the next phase from them (`next_phase`), runs it under the watchdog (`run_ddrescue`), and
looks at what happened:

```
meta → copy → scrape → retry → zones → report → extract
```

- `meta`: NTFS only, once (see "Metadata first").
- `copy`: `ddrescue -n` (no trimming, no scraping): read what reads, skip what does not.
- `scrape`: read the skipped areas sector by sector.
- `retry`: `-r N` passes over the unreadable sectors.
- `zones`: the deferred zones, last (below).
- `report` / `extract`: the file level (below).

A phase counts as "not needed" when the map has no block of the kind it works on (non-tried for `copy`,
non-trimmed/non-scraped for `scrape`, bad-sector for `retry`), looking only outside the deferred zones.

**The copy phase always starts from pass 1.** The status line of the map records a pass. If ddrescue continued from
pass 5 — which it does after any earlier stop — its `-a` (minimum rate) would not apply and it would skip neither
errors nor slow places, which is exactly what the copy phase exists for. So before every copy run the tool rewrites
the status line (`set_map_pos`) to "position unchanged, pass 1" (or to `--start-at` on the very first run).

**Safety stops.** A phase that ends three times in a row without the map changing, or ddrescue failing five times in
a row without progress, stops the tool instead of looping forever. Deferred zones that cover the whole device leave
nothing outside them to read, and `has` knows it.

## File system families

`fsstat` names the file system and `fs_kind_of` maps it to a family: `ntfs`, `ext` (ext2/3/4) or `fat` (FAT12/16/32,
exFAT). The family decides three things and nothing else:

- the unit of the pieces `file_map` reports (`CLUSTER`): the cluster of NTFS, the block of ext, the sector of
  FAT/exFAT (`istat -r` lists FAT runs in sectors);
- how `file_map` reads `istat -r`: NTFS needs its attribute-list logic (`file_map_ntfs`); ext and FAT print a plain run
  list, where a `Filler` before the first run and `Sparse` runs are holes (zeros), and ext inline data is resident
  (`file_map_blocks`); both end in the same normalisation (`file_map_normalize`: sort, merge neighbours, mark a file
  `broken` if the pieces leave a hole or fall short of the size);
- the listing rules in `tsk_files`: NTFS drops its system files, named streams and stale index entries; ext keeps
  names like `$x` and `a:b`, drops directories and looks for allocated inodes the walk did not reach (`?/entry N`);
  FAT and exFAT drop their pseudo files (`$FAT1`, `$ALLOC_BITMAP`, …) and have no table to compare the walk with.

FAT and exFAT are recognised from the boot sector (`boot_probe`) and the "fsstat output" for them is synthesised
(`fs_probe`): `fsstat` of The Sleuth Kit 4.12 does not return on exFAT (it was observed spinning for minutes), and
the other `fsstat` calls run under a time limit for the same reason. The metadata-first phase knows only NTFS.

## Metadata first

With a dying disk the order of reading decides what survives. Before the ordinary copy, on an NTFS volume, the tool
reads (`meta_run`), each step with the same watchdog, recovery and deferred-zone logic as a targeted recovery
(`rescue_ranges`, with the zones cut out of the ranges):

1. the first MiB of the disk (partition table), then the first 64 KiB of every partition (boot sectors);
2. from each NTFS boot sector (`ntfs_geometry`: sector and cluster size, the `$MFT` and `$MFTMirr` clusters, the size
   of an MFT record) the first MiB of the MFT and the mirror — enough for `fsstat` and `istat` to open the volume on a
   partly read image;
3. the data of `$Volume`, `$AttrDef` and `$UpCase` (`attr_ranges`, found by attribute number: until `$AttrDef` has
   been read, TSK cannot name the attribute types and cannot find a directory index at all — a listing of such an
   image shows nothing useful, which is also why an inventory of an early image is meaningless without this phase);
4. all runs of `$MFT` (`file_byte_ranges 0`);
5. the directory indexes: `fls -r -p -u -D` lists the directories that can be reached with what has been read so
   far, `istat -r` gives the runs of their `$INDEX_ALLOCATION`, those are read, and the next pass reaches the
   directories below (at most eight passes; small directories live inside the MFT);
6. the data of the `--first` paths (`tsk_files` filtered by path, `file_byte_ranges`).

The markers `meta.done` and `first.done` make the phase run once; a new `--first` path later reads just that path.
When the volume is not NTFS (or the structures cannot be opened) the phase says so and the ordinary order follows.

## The watchdog

Every `--interval` seconds, while ddrescue runs:

1. **The device.** `device_ok` checks `/sys/block/X/device/state` is `running` and reads one 4096-byte block with
   `O_DIRECT`. If the disk is gone, see "A dropped disk" below.
2. **The temperature.** `smartctl -j -A` + `jq '.temperature.current'`. At `--stop` ddrescue gets `SIGTERM` — not
   `SIGINT`: background processes of a script without job control ignore `SIGINT` — and the map is saved by ddrescue
   on its way out. The tool then waits until the temperature is `--resume` or below (the hysteresis is required so that
   it does not stop and start every minute), and resumes the same phase.

smartctl's exit status is a bit mask that also reports on the health of the disk (a worn disk returns non-zero while
the JSON is perfectly good), so it is ignored; the JSON either has the temperature or it does not. For a disk behind
a USB bridge the plain call usually fails and `-d sat` works, so the tool tries both once at the start. Without any
source it runs unwatched and says so. `--temp-cmd PROGRAM` replaces smartctl with a program (also useful in tests).

While rescuing, the kernel's command timeout of the disk (`/sys/block/X/device/timeout`, 30 s by default) is raised
to 180 s and restored on exit: a disk without ERC re-reads a sector for a long time, the kernel resets the link
after 30 s and, after a few resets, disables the disk.

## The kernel's read-only flag

`ddrescue` never writes to its input, but something else might: a desktop that auto-mounts the partition and replays
a journal, an `fsck` started by hand. While rescuing, `blockdev --setro` is set on the source device (`set_readonly`);
the original value is restored on exit. A disk that comes back is a new device and gets the flag again
(`recover_device`). If the flag cannot be set the tool warns and goes on.

## Status, events, the service

The watchdog loop writes `NAME.logs/state` (state, phase, temperature, rescued bytes and the rate over a ten-minute
window of the map — ddrescue's own rate log is written only when it exits) once per interval. `--status` combines it
with the map (exact byte totals per block kind), the lock (a held lock means a rescue is running), the deferred zones
and the tail of `rescue.log`. `notify` runs `--on-event PROGRAM` in the background with a 60 s limit and without a
shell. `service_unit` prints a unit for the same command line: exit status 3 (power cycle) and 2 (stuck zones) are
excluded from `Restart=`, and the unit is wanted by `multi-user.target`, so the first boot after the power cycle
continues the rescue.

## Triage

`--triage` is a separate, read-only mode. It reads `smartctl -j -i -H -A` (plain, then `-d sat`), the kernel log
(link resets of the disk's ATA port, I/O errors for the device) and nine 1 MiB samples with `O_DIRECT`. A sample that
does not return in `--triage-timeout` seconds is abandoned (the process may stay in the kernel for its own timeout)
and sampling stops; so it does after two failures in a row. Findings are graded — notes, warnings (SMART failing,
pending or uncorrectable sectors, CRC errors, failed or slow samples, link problems) and red flags (the disk does not
answer) — and the verdict follows the worst grade.

## A dropped disk

When a disk hangs, the kernel eventually drops it. A vanished disk answers every read with an error, *instantly*, and
ddrescue — which cannot tell a vanished disk from a bad area — would mark the entire remainder (hundreds of
gigabytes, in minutes) as non-trimmed or bad. So:

1. The watchdog notices (`device_ok` fails) and stops ddrescue at once (`SIGTERM`; the exit code 11 inside the tool).
2. **Traces** are returned to "not tried" (`revert_artifacts`): blocks `*` (non-trimmed) and `/` (non-scraped), and
   `-` (bad) areas larger than `--artifact-bad` (16 MiB) in one piece — real bad areas are small. A copy of the
   previous map is kept next to it (`.before-revert`; an earlier copy becomes `.before-revert.prev`). The same cleanup runs at the start if the map holds more than
   `--artifact-limit` (1 GB) of such traces, because a previous run may have been killed before it could clean up.
3. A zone is deferred around the place where the disk hung (below).
4. **Bringing the disk back** (`recover_device`): wait `--rescan-pause`, write `- - -` to
   `/sys/class/scsi_host/hostN/scan` (that makes the kernel poll the port again), wait for the device path to
   reappear, re-resolve the device name (it may have changed — hence `/dev/disk/by-id/...`), restore the kernel
   timeout and check with `device_ok`. At most `--rescan-attempts` times in a row without progress in the map; then
   the tool asks for a power cycle. The SCSI host is saved in `NAME.logs/scsi-host`, so that a missing disk can be
   brought back at the start of the next run.

A host rescan helps libata (SATA) and SAS hosts. A USB device that dropped is gone at the USB layer and a rescan of
its storage host does not bring it back; an NVMe controller has no SCSI host at all. For those transports the tool
says why it cannot rescan and asks for a power cycle. (A USB reset through `authorized` is not implemented because it
has not been tested.)

## Deferred zones

Some places make the disk hang rather than fail. Reading them in order means losing hours (and the disk) in the
same place every time. Instead:

- **Where the disk hung.** ddrescue's rate log (`--log-rates`) says where it was reading; the last position with a
  non-zero rate is the hang position (`hang_position`). The log is buffered and written when ddrescue exits, so it is
  read *after* the run has ended.
- **A zone** `[p − margin, p + margin)` is deferred (`zone_put`; overlapping zones merge; the margin is
  `--zone-margin`, 1 GB). Zones are kept in `NAME.logs/zones` as `START END DIRECTION FAILURES`.
- **Everything else first.** While zones exist, ddrescue works on a *domain* map (`-m`) that excludes them
  (`write_domain outside`).
- **Zones last, one at a time, alternately from the start and from the end** (`DIRECTION` is `f` or `r`; for `r`
  ddrescue runs with `-R`). The reading position is set explicitly in the map before each attempt, otherwise
  ddrescue would continue from where it hung, not from the edge of the zone.
- **Each hang narrows the zone by exactly what was rescued** (`zone_hang`, using `unrescued_span` on the *map*: the
  rate log is too coarse and narrowing by it looped forever). Unreadable sectors (`-`) at the edge do not block this:
  they are left for the retry phase.
- **Cores.** An attempt that narrows the zone by less than `--zone-min-progress` (16 MiB) is a failure. Two failures
  in a row mean the disk does not read this zone from either side: it is a *core*, and `zone_next` skips it. When only
  cores remain, the tool exits with status 2. `--give-up-zones` abandons them: the report lists the files that lie in
  them as damaged.
- **A zone that has been read** completely becomes an ordinary part of the disk again; its bad sectors go through
  `scrape` and `retry`.
- `--add-zone FROM-TO` defers a zone by hand, once: the zone is remembered in `zones.added` and not added again,
  otherwise a zone that has been narrowed would widen back.

## The file level

### Why not mount the image

Mounting fails exactly when it is needed. A directory whose index lies in an unread area cannot be opened (`EINVAL`),
and after a disk failure the NTFS driver often refuses the volume altogether (`$MFTMirr` does not match `$MFT`).
The Sleuth Kit parses the volume directly:

- `fls -r -p -u` lists files with full paths. Paths are rebuilt from the parent reference of each MFT entry, so they
  survive an unreadable directory index.
- `istat -r` says where the data of an entry lies (the runs) and when it was modified.
- `icat` reads resident (stored inside the MFT entry) and compressed data.
- `fsstat` identifies the file system and the cluster size; `ils -a` lists allocated entries.

The file system is detected with `fsstat`. If it is not NTFS, or the image has a partition table, the file level is
skipped with a message; imaging itself works for anything.

### Whole-disk images

If `fsstat` does not recognise the image itself, `mmls` lists its partitions (`mmls_starts`, with the device's
sector size, kept in `NAME.logs/sector-size` for runs without the disk), every partition is tested with `fsstat -o`,
and the NTFS one is used (`fs_locate`; `--partition N` chooses among several). TSK takes the offset in 512-byte
sectors (`TSK_O`); every byte position that comes out of the file level (ranges for classification, targeted and
metadata-first reads, the stream of a file) includes `FS_OFFSET`.

### Preparing the image

Until ddrescue has reached the end, the image is shorter than the partition, and reads past its end would abort the
parse of the volume. So the image is extended (`truncate`, sparse) to the size of the partition. The data is not
changed.

### The list of files

`tsk_files` builds `ID<TAB>PATH`:

- system files (`$…`) and named streams (a path with `:`) are skipped;
- entries that point to an MFT entry that is readable and *not in use* (stale index records of deleted files) are
  skipped — they are not files. `ils -a` only saves work: whatever it does not list as allocated is checked with
  `istat`, and an entry that cannot be read is kept (it will be `unknown`) rather than lost;
- an *allocated* entry that the directory walk did not reach (its parent is unreadable) is **not** dropped: it is
  listed as `?/NAME` and counts as incomplete. Silently losing a file is worse than listing a spurious one.

### Classification

Every file is reduced to its runs (`file_map`) and compared with the unread parts of the map (`classify`):

- `intact` — no byte of its data is in an unread range;
- `damaged` — some are (the count is reported);
- `unknown` — the entry cannot be parsed, or its pieces do not add up. Better downloaded or copied again.

Sparse pieces are zeros by definition and never damage a file. Resident data is inside the MFT entry; the MFT is
read like any other file.

### The `$ATTRIBUTE_LIST` problem (The Sleuth Kit 4.12)

A heavily fragmented file has so many runs that the list does not fit into its MFT entry. NTFS then adds an
`$ATTRIBUTE_LIST` to the base entry and continues the data attribute in **extension entries**. The list says, for
each attribute, in which entry it lives and from which VCN (virtual cluster number) it starts.

The Sleuth Kit 4.12 stitches such files together **incorrectly** in some cases. Observed on a real volume with large
(multi-gigabyte) video files whose lists spanned hundreds of MFT entries:

- a piece that lives in the base entry goes into a *separate* attribute (a different attribute id), and in the
  stitched run list it is replaced by a filler — `icat` then returns zeros there, at the right size;
- the pieces of some entries are shifted by thousands of clusters;
- in one file most of the tail was missing;
- the size and the initialised size reported for the file can be wrong.

The ordinary tools therefore returned a file of the right length with zeros or foreign data in the middle, with no
error. `file_map` does not use TSK's stitching at all:

1. `istat -r` of the base entry gives the attribute list lines (`Type: 128-ID  MFT Entry: ENTRY  VCN: START`).
2. Every entry mentioned for a data attribute (type 128) is read with `istat -r` itself.
3. From each entry only the runs of its *own* data attribute are taken, and only inside its range `[lo, hi)` by the
   list (`lo` is the VCN the list gives for that entry and attribute id; `hi` is the next larger VCN in the list). A
   data attribute that the list does not mention is a stitch and is ignored. Filler runs only advance the VCN.
4. The size and the initialised size come from the attribute that starts at VCN 0.
5. The pieces are sorted by VCN and checked: a hole, an overlap or a total shorter than the size makes the file
   `broken`, which counts as unknown/incomplete — never as intact. A compressed file with an attribute list is `broken`
   too, since `icat` cannot be trusted there either.

Such files are copied out of the image piece by piece with `dd` (`file_stream`); `icat` is used only for resident
and compressed (single-attribute) data. On synthetic volumes with files in 1400–3000 pieces and 13 list entries
TSK's own stitching was correct, so the failure above could not be reproduced synthetically; the unit tests carry
real `istat` output of such a file and hand-built cases of the shapes described (a middle chunk under another
attribute id, shifted stitching, holes, overlaps), and the integration tests check byte-for-byte extraction of two
fragmented files. If you can reproduce the problem with a small volume, it is worth reporting to the project.

### Silent garbage

A worn disk can return something other than data *without an error*. ddrescue then counts the place as read and the
map is clean. Observed on a failing 2.5" SMR drive: service sectors with the tag `sEDU` at the start and at the end of
the 512-byte sector, and 128 KiB of zeros. The data stream of every extracted file is checked with `grep -aP` for
`sEDU\x00{504}sEDU` or a run of zeros; files that match are extracted but listed in `suspicious-files.txt`. A PCRE
repeat count is at most 65535, hence the nested form `(?:\x00{32768}){4}` for 128 KiB. Patterns and the zero
threshold are options. A long run of zeros is normal in sparse files and disk images, so this is a heuristic and the
list is advice, not proof.

### Garbage in the image (`--recheck-garbage`)

`scan_garbage` runs `grep -aboP` over the image with a pattern wrapped in a lookahead, so that every match is one
byte (the printed match of a pattern with NUL bytes or newlines would break the parsing); the offsets become
sector-aligned ranges. The phase runs twice around a retry: the first time it marks the finished (`+`) parts of the
map inside the ranges as bad (`mark_map_ranges`, an explicit rewrite of the blocks) and removes `retry.done`; the
retry phase then reads those sectors again; the second time it scans again and keeps what is left in
`garbage-ranges.txt`. `unread_ranges` adds that file to the unread ranges of the map, so `report`, `--inventory` and
targeted recovery classify files that touch garbage as damaged. Zeros are not scanned for: unused space is full of
them and marking it would send the disk to re-read gigabytes for nothing.

### Extraction

- Files are written to `NAME.part` and renamed when the size matches the volume; the modification time is set from
  the volume (`istat` times, UTC).
- A destination with the same size and time is skipped, which makes extraction interruptible and repeatable.
  Size and time alone do not catch a copy whose write was cut short (a USB bridge that loses data on a disconnect):
  re-check the last files after such an event.
- Files are written as `--owner` (via `runuser`) so that a setgid directory passes its group on.
- With `--verify` the stream is hashed on the way (`tee` into `sha256sum`), then the file on the target is synced
  (`sync FILE`), dropped from the page cache (`dd iflag=nocache count=0`), read back and hashed; a difference removes
  the copy and fails the run at the end. Hashes go to `manifest.sha256` (`HASH  PATH`, the format of
  `sha256sum -c`); a file already in place with the same size and time is compared with its manifest entry, or with
  a hash computed from the image when there is none.

## Shell lessons built into the code

- **`awk -v` interprets backslashes** in the value. Paths and patterns reach awk through the environment (`ENVIRON`).
- **`pgrep -f` finds the waiting shell itself** (its command line contains the pattern). Use `pgrep -x` plus an
  argument check.
- **A running bash script must not be overwritten in place** — bash reads a script as it runs. Replace it by writing a
  new file and `mv`.
- **ddrescue buffers its rate log** and writes it on exit.
- **Locale.** The script sets `LC_ALL=C`: the output of `ddrescuelog -t`, `istat`, `numfmt` and the sort order are
  parsed, and decimal commas break all of them.
- **Do not leak the run lock.** The lock is a file descriptor; a child that outlives the tool (the `sleep` of the
  watchdog loop, a `tee`) would keep the next run out, so long-lived children are started with the descriptor closed.
- **Output inside a redirected loop.** A message printed to stdout inside `while … done >file` lands in the file; the
  zone list was once corrupted this way.
- **`grep -q` at the end of a pipeline** with `pipefail` gives false negatives through `SIGPIPE`; the lint forbids it.
