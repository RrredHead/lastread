# lastread

`lastread` images a failing disk or partition with [GNU ddrescue](https://www.gnu.org/software/ddrescue/)
**without killing it**, and then recovers files from the image. The failing disk is only ever read.

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
- **A file level for NTFS**, without mounting the image (The Sleuth Kit): which files are intact, which are damaged,
  recovery of chosen files only, extraction of intact files with their original times, and detection of garbage the
  disk returned *without* an error.

It does not repair anything and never writes to the source device.

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

2. Image it. The directory must exist, have enough room for the whole device and be **on another physical disk**:

   ```bash
   sudo lastread /dev/disk/by-id/ata-EXAMPLE_DISK-part1 --dir /mnt/big/rescue
   ```

   This creates `NAME.img`, `NAME.map` and `NAME.logs/` in the directory (`NAME` is the last part of the source
   path unless you pass `--name`; for a name that can change, such as `/dev/sdb1`, `--name` is required, because the
   next run must find the same image). Stop it any time; run the same command to continue.

3. Look at what is damaged, and take what is intact — the disk is no longer needed:

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
| `copy` | ddrescue reads everything that reads fast; bad and slow places are skipped (`ddrescue -n`). Always restarted from pass 1 at the current position. |
| `scrape` | skipped areas are read sector by sector |
| `retry` | unreadable sectors are tried `--retries` more times |
| `zones` | deferred zones, last, one at a time, alternately from the start and the end |
| `report` | summary; with the file level, the list of damaged files |
| `extract` | with `--extract`: intact files are copied out of the image |

Exit status: `0` done, `1` error, `2` only stuck deferred zones are left (see `--give-up-zones`), `130` interrupted.

Files in `NAME.logs/`: `rescue.log` (the run log), `events.log` and `rates-*.log` (ddrescue's event and rate logs),
`ddrescue-PHASE.log` (its output), `zones` (the deferred zones), `scsi-host` (where to rescan), and the lists.
How the pieces work is described in [docs/how-it-works.md](docs/how-it-works.md).

## Options

```
lastread SOURCE [options]
lastread --inventory [--name NAME] [options]
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

**Silent garbage** — `--suspect-pattern RE` (repeatable), `--suspect-zeros SIZE` (128Ki), `--no-suspect-check`.

**General** — `--dry-run`, `--help`, `--version`.

Sizes accept `k`/`M`/`G`/`T` (powers of 1000) and `Ki`/`Mi`/`Gi`/`Ti` (powers of 1024).

## Recipes

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
  wait, power on and run the same command again.
- **Silent garbage.** Some failing disks return something else instead of data and report no error, so ddrescue
  counts the place as read. Extraction checks the data stream and lists such files in `suspicious-files.txt`
  (they are still extracted): a 512-byte service sector tagged `sEDU` at both ends (seen on a failing 2.5" SMR drive)
  and, by default, a run of 128 KiB of zeros. Long runs of zeros are legitimate in sparse files, disk images and some
  databases: raise `--suspect-zeros SIZE` or turn the check off (`--suspect-zeros 0`, `--no-suspect-check`).
  Replace the pattern with `--suspect-pattern RE` (`grep -P`, bytes).
- **Check the target after an abrupt disconnect.** Skipping "already extracted" files by size and time does not
  catch a file whose write was cut short (for example a USB bridge that drops data on a disconnect). If the
  extraction target went away in the middle of a run, extract the last files again into a scratch directory and
  compare them with `cmp`, or delete them and extract again.
- **Run it in `tmux`/`screen`** and keep the image on a disk with free space for the entire device.
- **The image is sparse** and grows as the disk is read; `truncate` is used to give it the size of the device.

## Limitations

- The file level supports NTFS only (resident, ordinary, sparse, compressed and heavily fragmented files). Other file
  systems and whole-disk images with a partition table are imaged normally and the file level says why it is
  skipped. The code is structured so that other file systems understood by The Sleuth Kit can be added later; this
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
tests/vm.sh integration       # device-mapper, scsi_debug and NTFS tests, as root in the VM
```

The integration tests create and destroy block devices: run them in a VM, never on a machine whose disks matter.
`docs/feature-matrix.md` maps every feature to its code and its test.

## Credits

Built on GNU ddrescue and The Sleuth Kit; it only calls them as programs.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE). The programs it calls (GNU ddrescue, The Sleuth Kit) run as separate
processes and keep their own licenses.
