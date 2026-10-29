# How lastread works

This document explains the parts that look odd. Almost every one of them is a fix for something that went wrong on a
real failing drive, and the tests keep them from being "simplified" back.

## The loop

The whole state is on disk: the ddrescue map (`NAME.map`) and a few files in `NAME.logs/`. Each time through the
loop the tool derives the next phase from them (`next_phase`), runs it under the watchdog (`run_ddrescue`), and
looks at what happened:

```
copy → scrape → retry → zones → report → extract
```

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

### Extraction

- Files are written to `NAME.part` and renamed when the size matches the volume; the modification time is set from
  the volume (`istat` times, UTC).
- A destination with the same size and time is skipped, which makes extraction interruptible and repeatable.
  Size and time alone do not catch a copy whose write was cut short (a USB bridge that loses data on a disconnect):
  re-check the last files after such an event.
- Files are written as `--owner` (via `runuser`) so that a setgid directory passes its group on.

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
