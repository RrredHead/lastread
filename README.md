# lastread

`lastread` images a failing disk or partition with [GNU ddrescue](https://www.gnu.org/software/ddrescue/)
while trying to reduce stress on it, and then recovers files from the image. The failing disk is only ever read.

It is one bash script around `ddrescue`. What it adds:

- **Resumable from anywhere.** The phase is chosen from the ddrescue map, so after any stop — overheating,
  Ctrl+C, the disk dropping off the bus, a reboot — running the same command continues where it stopped.
- **A watchdog.** Every `--interval` seconds it checks the disk temperature (`smartctl`) and that the disk still
  answers. Too hot: ddrescue is stopped and resumed when the disk has cooled down.
- **Deferred zones.** Places where the disk hangs are set aside, everything else is read first, and the zones are
  attacked last, one at a time, alternately from the start and from the end, until only an unreadable core is left.
- **A dropped disk is handled.** ddrescue is stopped before it marks the whole remainder as bad (a vanished disk
  answers every read with an error, instantly). The traces are put back to "not tried" and, on SATA/SAS, the disk is
  brought back by rescanning its SCSI host — no power cycle.
- **The structures of the volume first.** On an NTFS volume the partition table, boot sector, `$MFT` and directory
  indexes — and then the paths you name with `--first` — are read before the rest of the disk, because with a dying
  disk the order of reading decides what survives.
- **A file level for NTFS, ext2/3/4 and FAT/exFAT**, without mounting the image (The Sleuth Kit), also for a
  whole-disk image with a partition table: which files are intact, which are damaged, recovery of chosen files only, extraction of intact
  files with their original times, and detection of garbage the disk returned *without* an error.
- **Made for long rescues.** `--triage` (a short read-only health check with a verdict), `--status` (progress without
  touching the disk, also as JSON), `--on-event` (a program is run when the disk gets hot, drops, needs a power cycle,
  …) and `--print-service` (a systemd unit that continues the rescue by itself after a power cycle).

It does not repair anything and does not intentionally write to the source device. During rescue it attempts to set
the kernel's read-only flag as an additional safeguard; if that fails, it warns and continues without it. No software
can guarantee that further reads will not worsen a failing drive.

## When not to use it

Do not use this on a disk whose data is valuable and whose failure looks mechanical. **Send it to a data
recovery lab** if you see any of these:

- clicking, knocking, scraping or beeping from the drive;
- the disk is not detected at all, or is detected with a wrong size or name;
- the drive was dropped, flooded, burnt, or smells burnt;
- an SSD that reports 0 bytes or a strange model name (controller failure);
- the data is irreplaceable and you cannot afford to lose even part of it.

Every extra minute a dying disk runs can cost data, and a lab can do things software cannot. `lastread` is for the
common middle case: a worn but alive disk — bad sectors, slow places, overheating, a flaky link — where the data
matters but the disk still answers.

Also: never run `fsck`, `chkdsk`, `ntfsfix` or mount the source read-write. Do all work on the image.

## Requirements

| What | Version (tested) | Needed for |
| --- | --- | --- |
| Linux, bash | bash ≥ 4.4 (5.2) | everything |
| GNU ddrescue | ≥ 1.27 (1.27) | imaging |
| util-linux (`lsblk`, `blockdev`, `flock`, `runuser`) | 2.39 | everything |
| GNU coreutils (`numfmt`, `stat`, `truncate`, `dd`, …), `grep` with `-P`, awk (mawk or gawk) | 9.4, 3.11, mawk 1.3.4 / gawk 5.2 | everything |
| smartmontools ≥ 7 (for `smartctl -j`) and jq | 7.4, 1.7 | the temperature watchdog (optional) |
| The Sleuth Kit | 4.12 (4.12.1) | the file level (optional) |
| whiptail | any | the `--pick` window (optional; plain questions without it) |
| systemd (`systemd-inhibit`) | any | keeping the machine awake (optional) |

Tested on Ubuntu 24.04 (kernel 6.8). Root is needed to read the device; `--inventory` and extraction from an
existing image work without it.

## Install

It is a single file:

```bash
sudo install -m 755 lastread /usr/local/bin/lastread
```

To update a copy that is *running* a rescue, write the new version to a temporary file next to it and `mv` it over
(bash reads a script while it runs; overwriting the file in place can break the running instance).

## Quick start

1. Find a stable name for the disk or partition. `/dev/sdX` can change when a dropped disk comes back:

   ```bash
   ls -l /dev/disk/by-id/
   ```

   The source must not be mounted. For a file-level recovery, image the **partition** (`...-part1`), not the whole
   disk.

2. *(Optional, recommended.)* A short look at the disk before you commit to a long run. It only reads:

   ```bash
   sudo lastread /dev/disk/by-id/ata-EXAMPLE_DISK-part1 --triage
   ```

   Triage performs real reads, which can stress a failing disk; skip it if those reads are not worth the risk.

   It prints the identity, SMART data (if the disk shows it), kernel messages about the disk and nine one-megabyte
   sample reads, then a verdict — green, yellow or red — and suggested options. Red means the disk barely answers:
   see "When not to use it".

3. Image it. The directory must exist, have enough room for the whole device and be **on another physical disk**:

   ```bash
   sudo lastread /dev/disk/by-id/ata-EXAMPLE_DISK-part1 --dir /mnt/big/rescue
   ```

   This creates `NAME.img`, `NAME.map` and `NAME.logs/` in the directory (`NAME` is the last part of the source
   path unless you pass `--name`; for a name that can change, such as `/dev/sdb1`, `--name` is required, because the
   next run must find the same image). Stop it any time; run the same command to continue.

4. Look at what is damaged, and take what is intact — the disk is no longer needed:

   ```bash
   sudo lastread --inventory --dir /mnt/big/rescue --name ata-EXAMPLE_DISK-part1 \
       --extract --extract-to /mnt/recovered
   ```

   The lists are in `NAME.logs/`: `inventory-intact.txt`, `inventory-incomplete.txt`, and after a full run
   `damaged-files.txt` and `suspicious-files.txt`.

Use `--dry-run` first to see what the tool would do.

## How a run goes

The phase is derived from the map every time, so there is nothing else to remember:

| Phase | What happens |
| --- | --- |
| `meta` | NTFS only, once: the partition table, boot sectors, `$MFT`, directory indexes, then the data of the `--first` paths — read before everything else. Skipped for other file systems and with `--no-meta-first` or `--no-fs`. |
| `copy` | ddrescue reads everything that reads fast; bad and slow places are skipped (`ddrescue -n`). Always restarted from pass 1 at the current position. |
| `scrape` | skipped areas are read sector by sector |
| `retry` | unreadable sectors are tried `--retries` more times |
| `zones` | deferred zones, last, one at a time, alternately from the start and the end |
| `report` | summary; with the file level, the list of damaged files |
| `extract` | with `--extract`: intact files are copied out of the image |

Exit status: `0` done, `1` error, `2` only stuck deferred zones are left (see `--give-up-zones`), `3` the disk does
not answer and needs a power cycle, `130` interrupted. (`--triage` returns `4` for a red verdict.)

Files in `NAME.logs/`: `rescue.log` (the run log), `events.log` and `rates-*.log` (ddrescue's event and rate logs),
`ddrescue-PHASE.log` (its output), `zones` (the deferred zones), `scsi-host` (where to rescan), `state` (what `--status`
reads), `meta.done`/`first.done` (the metadata-first phase), and the lists.
How the pieces work is described in [docs/how-it-works.md](docs/how-it-works.md).

## Options

```
lastread SOURCE [options]
lastread --inventory | --status [--json] [--name NAME] [options]
lastread SOURCE --triage
lastread SOURCE [options] --print-service
```

Run `lastread --help` for the full list with defaults. The groups:

**Layout** — `--dir DIR` (default: the current directory; must exist), `--name NAME` (required unless SOURCE is under
`/dev/disk/` or `/dev/mapper/`).

**Watchdog** — `--stop C` (48), `--resume C` (44), `--interval SEC` (60), `--temp-cmd PROGRAM`, `--smart-type TYPE`,
`--no-temp`. `PROGRAM` is run with the whole-disk device as its only argument and prints °C (no shell involved); the
default can come from `$LASTREAD_TEMP_CMD`. Without a working temperature source the tool says so and runs unwatched.
The hysteresis is mandatory: `--resume` must be below `--stop`.

**Reading** — `--min-rate RATE`, `--skip-size SIZE`, `--retries N` (3), `--reverse`, `--start-at POS`. They
set `ddrescue -a`, `-K`, `-r`, `-R` for the copy phase (and `--start-at` only for the first copy run).

**Deferred zones** — `--add-zone FROM-TO` (once per zone), `--give-up-zones`, `--zone-margin SIZE` (1G),
`--zone-min-progress SIZE` (16Mi).

**Dropped disk** — `--rescan-pause SEC` (60), `--rescan-attempts N` (3), `--no-rescan`, `--kernel-timeout SEC` (180;
0 leaves the kernel alone), `--artifact-limit SIZE` (1G), `--artifact-bad SIZE` (16Mi).

**File level** — `--extract`, `--extract-to DIR`, `--include PREFIX` (repeatable), `--map SRC:DST` (repeatable),
`--owner USER[:GROUP]`, `--file-mode MODE` (0664), `--dir-mode MODE` (0775), `--extract-damaged`, `--inventory`,
`--pick`, `--file PART` (repeatable), `--no-fs`.

**Order** — `--first PATH` (repeatable): read this directory or file of the volume right after its structures;
`--no-meta-first`: no metadata-first phase.

**Whole-disk images** — `--partition N`: which partition of the image's table holds the volume when several hold a
file system the file level can read.

**Safety and notifications** — `--no-readonly` (do not set the kernel's read-only flag on the source), `--on-event
PROGRAM` (default from `$LASTREAD_ON_EVENT`), `--print-service`.

**Looking** — `--triage` and `--triage-timeout SEC` (20); `--status` and `--json`.

**Silent garbage** — `--suspect-pattern RE` (repeatable), `--suspect-zeros SIZE` (128Ki), `--no-suspect-check`,
`--recheck-garbage`.

**Verification** — `--verify` (with `--extract`).

**General** — `--dry-run`, `--help`, `--version`.

Sizes accept `k`/`M`/`G`/`T` (powers of 1000) and `Ki`/`Mi`/`Gi`/`Ti` (powers of 1024).

## Resume safety

Keep the image and map together: a map without its image, or an image shorter than rescued ranges, is refused.
This cannot detect an image replaced by another file of the same size or sparse holes. On the first run lastread
records available device identifiers and partition geometry in `NAME.logs/source.identity` and checks them on resume
and after a reconnect. If the identity changes or cannot be read, it stops; after independently verifying the source,
`--accept-source-change` adopts the new identity on the next run; remove the option afterwards, including from any
systemd unit, so later changes are checked. Older rescues without an identity record are adopted
with a warning. If no stable identifier is available, a warning explains that identity cannot be reliably checked.

lastread compares available block-device ancestry of the source and destination, including device-mapper and RAID.
When ancestry cannot be determined, or a multi-device filesystem such as btrfs is involved, it warns: independently
ensure every destination is on a different physical disk. These checks are safeguards, not proof.

## Recipes

### Check the disk before a long run

```bash
sudo lastread /dev/disk/by-id/ata-EXAMPLE_DISK --triage
```

The check reads nine 1 MiB samples (the start, seven points between, the end) with `--triage-timeout` seconds each,
stops after two failures in a row or after one read that does not return, and never reads more. A sample read is
still a read on a sick disk; that is why it is short. The verdict is a heuristic: green is "nothing alarming in this
short check", yellow is "workable, expect trouble", red is "the disk barely answers" (exit status 4). The SMART part
is read from `smartctl -j` (a plain call, then `-d sat` for a disk behind a USB bridge); it was written to the
documented JSON layout and is tested on prepared documents, not on real drives.

### Watch a long rescue

A rescue takes days and sometimes stops for a power cycle. Three tools help:

```bash
lastread --status --dir /mnt/big/rescue --name old-disk          # no root, does not touch the disk
lastread --status --json --dir /mnt/big/rescue --name old-disk   # for monitoring (needs jq)
sudo lastread DISK --dir /mnt/big/rescue --on-event ~/notify.sh  # a program is run on events
```

`--status` shows whether the rescue is running, the next phase, the rescued share, the unread and unreadable
amounts, the rate over the last ten minutes with a rough time left, the temperature, the deferred zones and the last
log lines. `--on-event PROGRAM` runs `PROGRAM EVENT MESSAGE` (no shell; the environment has `LASTREAD_EVENT`,
`LASTREAD_MESSAGE`, `LASTREAD_NAME`, `LASTREAD_DIR`, `LASTREAD_STATUS`) in the background on: `started`, `hot`,
`cooled`, `dropped`, `recovered`, `power-cycle`, `zones-stuck`, `phase-done`, `done`, `interrupted`, `failed`. A
failing program never stops the rescue.

To continue by itself after a power cycle, let systemd run it:

```bash
lastread DISK --dir /mnt/big/rescue --name old-disk --print-service | sudo tee /etc/systemd/system/lastread-old-disk.service
sudo systemctl daemon-reload && sudo systemctl enable --now lastread-old-disk.service
```

The unit restarts the tool after an ordinary failure (a few times), but not after exit status 3 (a power cycle is
needed — it starts again at the next boot), 2 (stuck zones — a decision is needed) or a stop by `systemctl`. When the
rescue is finished: `systemctl disable lastread-old-disk.service`.

### Important files first

```bash
sudo lastread /dev/disk/by-id/ata-EXAMPLE_DISK-part1 --dir /mnt/big/rescue --first 'Documents' --first 'Photos/2019'
```

On an NTFS volume the structures needed to know the files are read first (`meta` phase), then the data of the
given paths, then the rest. Without `--first` the structures are still read first; `--no-meta-first` switches the
phase off. The deferred zones stay out of this phase: a place where the disk hangs is set aside, as always. On a
volume that is not NTFS the phase says so and the ordinary order follows.

### A whole disk instead of a partition

```bash
sudo lastread /dev/disk/by-id/ata-EXAMPLE_DISK --dir /mnt/big/rescue --name old-disk --extract --extract-to /mnt/recovered
```

If the image has a partition table, the only partition with a file system the file level can read (NTFS, ext2/3/4,
FAT, exFAT) is found and used (through `mmls`); with several, the
tool says so and `--partition N` chooses (N counts the partitions as `/dev/sdX1`, `/dev/sdX2`, … do). Other file
systems are imaged normally and the file level says why it is skipped.

### Garbage that the disk returns without an error

Extraction already lists files with suspicious data (see the tip on silent garbage). With `--recheck-garbage` the
tool goes further: once, after copy, scrape and retry, it scans the *image* for the suspect pattern (the `sEDU`
service sector, or your `--suspect-pattern`; the zero-run check is not used here, because zeros are normal in
unused space), marks those sectors as unreadable so that the retry phase asks the disk for them again — a worn disk
sometimes answers correctly the second time — and scans once more. What still looks like garbage is kept in
`NAME.logs/garbage-ranges.txt` and counts as unreadable: files that touch it are damaged and are not extracted.
It works for any file system; it reads the whole image once, which takes as long as `grep` needs for the size of
the disk.

### Just take an image

```bash
sudo lastread /dev/disk/by-id/ata-EXAMPLE_DISK --dir /mnt/big/rescue --name old-disk --no-fs
```

Works for any device and any file system (including a whole disk with a partition table). The result is a plain
`old-disk.img` plus the map; mount the image read-only with a loop device later (`losetup -r -P`).

### A laptop disk that overheats

The defaults already stop at 48 °C and resume at 44 °C. Tune with `--stop`/`--resume`; check interval `--interval`.
Behind a USB bridge the plain `smartctl` call usually fails, and the tool then tries `-d sat` by itself; force it
with `--smart-type sat`. A custom sensor: `--temp-cmd ./my-sensor`. Cooling takes much longer than heating, so
expect pauses of 15–25 minutes. Keep the laptop on AC power: the tool inhibits sleep and the lid switch while it runs
(`systemd-inhibit`), but it cannot do anything about an empty battery.

### A disk that drops off the bus

Use the `/dev/disk/by-id/...` name — the tool re-resolves it after the disk returns. On SATA/SAS the tool rescans the
SCSI host (`echo "- - -" > /sys/class/scsi_host/hostN/scan`, as root) after `--rescan-pause` seconds, up to
`--rescan-attempts` times in a row without progress, then asks for a power cycle. The host is remembered in
`NAME.logs/scsi-host`, so the next run can bring a missing disk back before it starts. For the kernel, a
command timeout of 30 s means a reset after a long retry and, after a few resets, disabling the disk; while
rescuing, the tool raises it to `--kernel-timeout` (180 s) and restores the old value on exit.

On USB and NVMe there is no host rescan that revives the device: the tool says so and asks for a power cycle (unplug
and replug, or power the machine off and on).

### List what is rescued without the disk

```bash
sudo lastread --inventory --dir /mnt/big/rescue --name old-disk
```

Works at any stage, even in the middle of a rescue (it refuses if another run holds the image). Gives the intact and
the incomplete files.

### Recover specific files first

```bash
sudo lastread /dev/disk/by-id/ata-EXAMPLE_DISK-part1 --dir /mnt/big/rescue --file 'Family photos/2019'
sudo lastread /dev/disk/by-id/ata-EXAMPLE_DISK-part1 --dir /mnt/big/rescue --pick
```

ddrescue then reads only the data of the incomplete files whose path contains the text (or that you tick in the
window): copy, scrape and retry restricted to those files, then they are re-checked. Add `--extract --extract-to DIR`
to extract the ones that became whole. Continue the normal rescue with the same command without `--file`/`--pick`.

### Extract

```bash
sudo lastread --inventory --dir /mnt/big/rescue --name old-disk --extract --extract-to /mnt/recovered \
    --include Photos --map Documents/Work:work-docs --owner alice
```

The tree of the volume is preserved below `--extract-to`. `--include` keeps only the given paths; `--map SRC:DST`
puts a directory (or one file) into the directory `DST`; with either of them only matching files are extracted.
Without them the whole volume is extracted — system folders such as `System Volume Information` and files such as
`pagefile.sys` included — so use `--include` to pick what you need. With `--inventory`, `--include`/`--map` only
choose the paths whose counts are printed (without them the counts are per top-level directory). Files are written as `NAME.part`
and renamed when complete; the modification time comes from the volume. A file already extracted with the same size
and time is skipped, so extraction can be interrupted and repeated.

By default only **intact** files are extracted. In a normal run, `--extract-damaged` also extracts damaged files,
with the unreadable parts as zeros; later runs will skip such a file because its size and time match, so delete it
before recovering it again.

### Skip the slow places first

```bash
sudo lastread SOURCE --dir D --min-rate 20M --skip-size 1Mi,1Gi
sudo lastread SOURCE --dir D --reverse            # read the copy phase from the end
sudo lastread SOURCE --dir D --start-at 1700G      # first run only: start here
```

### Give up a zone the disk will not read

When only stuck zones are left the tool exits with status 2. To stop trying them and report the files inside as
damaged: run the same command with `--give-up-zones`.

## Tips

- **A disk that will not keep its link up:** try forcing a slower SATA speed with the kernel parameter
  `libata.force=N:1.5Gbps` (`N` is the ATA port number from `dmesg | grep -i 'ata[0-9]'`; see the kernel's
  `kernel-parameters.txt` for the syntax). Remove it afterwards.
- **Cold power-off:** if a disk drops and does not come back by rescanning, do a full power-off (not a reboot),
  wait, power on and run the same command again (or let `--print-service` do the last step).
- **The read-only flag.** lastread attempts to set `blockdev --setro` as an additional kernel safeguard against
  accidental writes. If it cannot, it warns and continues unprotected. The old value is restored on normal cleanup;
  the flag is set again on a returning device. `--no-readonly` disables it.
- **Silent garbage.** Some failing disks return something else instead of data and report no error, so ddrescue
  counts the place as read. Extraction checks the data stream and lists such files in `suspicious-files.txt`
  (they are still extracted): a 512-byte service sector tagged `sEDU` at both ends (seen on a failing 2.5" SMR drive)
  and, by default, a run of 128 KiB of zeros. Long runs of zeros are legitimate in sparse files, disk images and some
  databases: raise `--suspect-zeros SIZE` or turn the check off (`--suspect-zeros 0`, `--no-suspect-check`).
  Replace the pattern with `--suspect-pattern RE` (`grep -P`, bytes).
- **Check the target after an abrupt disconnect.** Skipping "already extracted" files by size and time does not
  catch a file whose write was cut short (for example a USB bridge that drops data on a disconnect). Use
  `--verify`: every extracted file is synced, dropped from the cache, read back and compared by SHA-256 with what
  the image gave, the hashes go to `NAME.logs/manifest.sha256` (`cd TARGET && sha256sum -c MANIFEST` checks them
  later, anywhere), and files that are already in place are checked the same way — against the manifest, or else
  against the image — and extracted again if they differ.
- **Run it in `tmux`/`screen`** and keep the image on a disk with free space for the entire device.
- **The image is sparse** and grows as the disk is read; `truncate` is used to give it the size of the device.

## Limitations

- The file level supports NTFS (resident, ordinary, sparse, compressed and heavily fragmented files), ext2/3/4
  (extents, holes, inline data), FAT12/16/32 and exFAT, on a partition image or on a partition of a whole-disk
  image. The metadata-first phase and the search for entries that the directory walk does not reach are NTFS and
  ext only; FAT/exFAT volumes are listed by the walk. Timestamps of FAT are stored without a time zone and are
  taken as UTC. Other file systems (btrfs, XFS, APFS, …) are imaged normally and the file level says why it is
  skipped. Other file systems are imaged normally and the file
  level says why it is skipped. The code is structured so that other file systems understood by The Sleuth Kit can be added later; this
  version does not promise them.
- Named streams and system files (`$…`) are not listed; file names containing a tab character cannot be put in the
  lists and are reported as `?/entry N`.
- Encrypted (EFS) files are copied as they are on disk.
- Without The Sleuth Kit, `--extract`, `--inventory`, `--pick` and `--file` refuse to start; a plain run still images
  the disk, says that the file level is pending, and does not record the report as done, so a re-run after installing
  `sleuthkit` produces it.
- No repair, no writing to the source, no GUI, no Windows or macOS support.
- Resetting a USB device (`authorized`) is not implemented.

## Development

```bash
tests/lint.sh                 # ShellCheck and style rules
tests/unit/run.sh             # unit tests: no root, no devices
tests/vm.sh create            # create a Multipass VM with the dependencies
tests/vm.sh integration       # device-mapper, scsi_debug, NTFS, ext4, FAT32 and exFAT tests, as root in the VM
```

The integration tests create and destroy block devices: run them in a VM, never on a machine whose disks matter.
GitHub Actions runs **Quick checks** on pushes to `main` and pull requests: lint, then unit tests with mawk and
gawk, excluding the timing-sensitive triage and callback tests. The longer **Integration tests (manual)** workflow runs only when started from the Actions tab (choose a branch
and click **Run workflow**) or with `gh workflow run integration.yml --ref BRANCH`. It runs each integration area as
a named stage, also runs those timing-sensitive unit tests, and stops subsequent stages after a failure. Check the job summary for skipped checks: a green run with
skips is not full coverage. GitHub-hosted runners may lack kernel modules or file-system support; run the full suite in
the Multipass VM above when needed. The manual workflow becomes available after its file is on the default branch.

`docs/feature-matrix.md` maps every feature to its code and its test.

## Credits

Built on GNU ddrescue and The Sleuth Kit; it only calls them as programs.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE). The programs it calls (GNU ddrescue, The Sleuth Kit) run as separate
processes and keep their own licenses.
