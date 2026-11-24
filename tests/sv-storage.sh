#!/usr/bin/env bash
#
# sv-storage.sh
#
# Purpose:
#   Tests sv-storage's decisions without touching any real drive: drive
#   classification, the internal-only new-drive check, which drives each
#   command offers or refuses, name validation and the fstab lines it
#   writes. Drive data comes from a saved `lsblk -J` fixture, and in that
#   mode sv-storage refuses every change except --dry-run.
#
# Inputs:
#   tests/fixtures/sv-storage-lsblk.json (a Fedora Atomic layout: /var/home
#   is a btrfs subvolume on the system NVMe)
#   tests/fixtures/sv-storage-lsblk-home-moved.json (the same computer with
#   the home folders already on a drive of their own)
#
# Usage:
#   tests/sv-storage.sh      (Linux; needs bash, jq and util-linux)
#
# Exit codes:
#   0 when every test passes, 1 otherwise.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly TOOL="${ROOT}/files/system/usr/bin/sv-storage"
WORK="$(mktemp -d)"
readonly WORK
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0

# expect
#   Records one test result.
#   Arguments: $1 test name, $2 "ok" when it passed, anything else when not,
#              $3 optional detail shown on failure
#   Returns: 0 always
expect() {
    if [[ "$2" == ok ]]; then
        PASSED=$((PASSED + 1))
        printf 'PASS  %s\n' "$1"
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL  %s\n' "$1"
        [[ -n "${3:-}" ]] && printf '%s\n' "$3" | sed 's/^/      /'
    fi
    return 0
}

# contains
#   Tells whether text contains a fixed string.
#   Arguments: $1 text, $2 string
#   Output: "ok" or "no" on stdout
#   Returns: 0 always
contains() {
    if [[ "$1" == *"$2"* ]]; then echo ok; else echo no; fi
}

# lacks
#   Tells whether text does not contain a fixed string.
#   Arguments: $1 text, $2 string
#   Output: "ok" or "no" on stdout
#   Returns: 0 always
lacks() {
    if [[ "$1" != *"$2"* ]]; then echo ok; else echo no; fi
}

# tool
#   Runs sv-storage against the fixture (FIXTURE picks another one), as an
#   administrator unless ADMIN is set to 0. SOURCE_BYTES stands in for the
#   size of the folder a move would copy.
#   Arguments: sv-storage arguments
#   Output: its combined output; the exit status is appended as "rc=N"
#   Returns: 0 always
tool() {
    local rc=0 out
    out="$(SV_STORAGE_LSBLK_JSON="${FIXTURE:-${ROOT}/tests/fixtures/sv-storage-lsblk.json}" \
        SV_STORAGE_SYSTEM_DISKS="${SYSTEM_DISKS-}" SV_STORAGE_SYSFS="${WORK}/sys" \
        SV_STORAGE_FSTAB="${WORK}/fstab" SV_STORAGE_ADMIN="${ADMIN:-1}" \
        SV_STORAGE_SOURCE_BYTES="${SOURCE_BYTES:-}" \
        bash "${TOOL}" "$@" </dev/null 2>&1)" || rc=$?
    printf '%s\nrc=%d\n' "${out}" "${rc}"
}

# make_sysfs
#   Builds a stand-in /sys/block where sdc and sdd sit on USB and sdh sits
#   behind a USB-to-SATA bridge (TRAN reports sata, only sysfs shows USB).
#   Arguments: none
#   Returns: 0 always
make_sysfs() {
    local pci="${WORK}/sys/devices/pci0000:00" name
    mkdir -p "${WORK}/sys/block"
    for name in nvme0n1 nvme1n1 sda sdb sde sdf sdg sdi; do
        mkdir -p "${pci}/0000:00:17.0/ata1/block/${name}"
        ln -s "${pci}/0000:00:17.0/ata1/block/${name}" "${WORK}/sys/block/${name}"
    done
    for name in sdc sdd sdh sdj; do
        mkdir -p "${pci}/0000:00:14.0/usb2/2-1/block/${name}"
        ln -s "${pci}/0000:00:14.0/usb2/2-1/block/${name}" "${WORK}/sys/block/${name}"
    done
}

make_sysfs
cat > "${WORK}/fstab" <<'FSTAB'
UUID=u-root / btrfs subvol=root 0 0
# sv-storage: storage Media
UUID=u-media  /var/mnt/Media  ext4  defaults,nofail,x-systemd.device-timeout=10s,x-gvfs-show,x-gvfs-name=Media  0  2
# sv-storage: apps apps (Flatpak)
UUID=u-apps-unplugged  /var/lib/flatpak  ext4  defaults,nofail,x-systemd.device-timeout=10s  0  2
FSTAB

# The system disk is found from its mount points alone here; real runs
# also follow findmnt sources through LVM and encryption.
SYSTEM_DISKS=""

out="$(tool list)"
expect "list: system NVMe is the system drive" \
    "$(contains "$(grep -A1 '^  nvme0n1 ' <<<"${out}")" "System drive")" "${out}"
expect "list: storage drive shows its folder" \
    "$(contains "$(grep -A1 '^  sdg ' <<<"${out}")" "Mounted at /var/mnt/Media (storage)")" "${out}"
expect "list: empty internal HDD is not set up" \
    "$(contains "$(grep -A1 '^  sda ' <<<"${out}")" "Not set up")" "${out}"
expect "list: hard drive described in words with size" \
    "$(contains "${out}" "ST4000DM004-2U9104 (hard drive, 4.0 TB)")" "${out}"
expect "list: NVMe described in words" \
    "$(contains "${out}" "WD_BLACK SN850X 1000GB (NVMe SSD, 1.0 TB)")" "${out}"
expect "list: old data noticed" \
    "$(contains "$(grep -A1 '^  sdb ' <<<"${out}")" "has data from before")" "${out}"
expect "list: USB stick is a USB drive" \
    "$(contains "$(grep -A1 '^  sdc ' <<<"${out}")" "USB drive")" "${out}"
expect "list: USB stick type in words" \
    "$(contains "${out}" "SanDisk Cruzer Blade (USB stick or card, 31 GB)")" "${out}"
expect "list: LUKS drive left alone" \
    "$(contains "$(grep -A1 '^  sdf ' <<<"${out}")" "Encrypted, RAID or LVM")" "${out}"
expect "list: unplugged role drive shows as configured" \
    "$(contains "$(grep -A1 '^  sdi ' <<<"${out}")" "Set up for /var/lib/flatpak")" "${out}"
expect "list: loop, zram, rom and empty readers hidden" \
    "$(for d in loop0 zram0 sr0 sdj; do grep -q "^  ${d} " <<<"${out}" && echo no && break; done; echo ok)" "${out}"

out="$(tool check)"
expect "check: exits 10 when internal drives are free" "$(contains "${out}" "rc=10")" "${out}"
expect "check: reports the empty internal HDD" "$(contains "${out}" "/dev/sda")" "${out}"
expect "check: reports the new internal NVMe" "$(contains "${out}" "/dev/nvme1n1")" "${out}"
expect "check: reports the internal SSD with old data" "$(contains "${out}" "/dev/sdb")" "${out}"
expect "check: gives the serial as identity" "$(contains "${out}" $'\tZFN-HDD-1\t')" "${out}"
expect "check: ignores the USB stick (RM=1)" "$(lacks "${out}" "/dev/sdc")" "${out}"
expect "check: ignores a USB hard drive that reports RM=0" "$(lacks "${out}" "/dev/sdd")" "${out}"
expect "check: ignores a hot-pluggable eSATA drive" "$(lacks "${out}" "/dev/sde")" "${out}"
expect "check: ignores a USB-SATA bridge seen only in sysfs" "$(lacks "${out}" "/dev/sdh")" "${out}"
expect "check: ignores the system drive" "$(lacks "${out}" "/dev/nvme0n1"$'\t')" "${out}"
expect "check: ignores drives in use or configured" \
    "$(for d in sdf sdg sdi; do [[ "${out}" == *"/dev/${d}"* ]] && echo no && break; done; echo ok)" "${out}"

SYSTEM_DISKS="/dev/nvme1n1"
out="$(tool check)"
expect "check: a disk found through findmnt counts as system" "$(lacks "${out}" "/dev/nvme1n1")" "${out}"
SYSTEM_DISKS=""

out="$(tool setup nvme0n1 --role storage --name X --fs ext4 --erase --yes --dry-run)"
expect "setup: refuses the system drive" "$(contains "${out}" "holds the system")" "${out}"
expect "setup: system drive refusal has no commands" "$(lacks "${out}" "would run")" "${out}"
out="$(tool setup /dev/nvme0n1p3 --role storage --name X --fs ext4 --erase --yes --dry-run)"
expect "setup: refuses a system partition named directly" "$(contains "${out}" "holds the system")" "${out}"
out="$(tool setup sdg --role storage --name X --fs ext4 --erase --yes --dry-run)"
expect "setup: refuses a mounted drive" "$(contains "${out}" "already in use")" "${out}"
out="$(tool setup sdf --role storage --name X --fs ext4 --erase --yes --dry-run)"
expect "setup: refuses an encrypted drive" "$(contains "${out}" "encrypted, RAID or LVM")" "${out}"
out="$(tool setup sdc --role storage --name X --fs ext4 --erase --yes --dry-run)"
expect "setup: sends USB sticks to sv-storage usb" "$(contains "${out}" "sv-storage usb")" "${out}"
out="$(tool setup sda --role storage --name Media --fs ext4 --erase --yes)"
expect "setup: fixture mode refuses real changes" "$(contains "${out}" "only --dry-run is allowed")" "${out}"

out="$(tool setup sda --role storage --name "Big Files" --fs ext4 --erase --yes --dry-run)"
expect "setup dry run: wipes the drive" "$(contains "${out}" "would run: wipefs -a /dev/sda")" "${out}"
expect "setup dry run: GPT with a Linux partition" "$(contains "${out}" "label: gpt; type=0FC63DAF")" "${out}"
expect "setup dry run: formats with the label" "$(contains "${out}" "mkfs.ext4 -F -L Big\\ Files /dev/sda1")" "${out}"
expect "setup dry run: fstab line uses UUID, nofail and timeout" \
    "$(contains "${out}" "UUID=<new-uuid>  /var/mnt/Big\\040Files  ext4  defaults,nofail,x-systemd.device-timeout=10s,x-gvfs-show,x-gvfs-name=Big%20Files  0  2")" "${out}"
expect "setup dry run: marker comment for later removal" "$(contains "${out}" "# sv-storage: storage Big Files")" "${out}"
expect "setup dry run: shows what is erased" "$(contains "${out}" "Everything on this drive will be erased")" "${out}"
expect "setup dry run: storage gets shared write access" "$(contains "${out}" "setfacl -R -m g:wheel:rwX")" "${out}"
expect "setup dry run: every default ACL entry is a default" "$(contains "${out}" "d:g:wheel:rwX\\,d:u:")" "${out}"
expect "setup dry run: succeeds" "$(contains "${out}" "rc=0")" "${out}"

out="$(tool setup nvme1n1 --role apps --name Apps --fs ext4 --erase --yes --dry-run)"
expect "setup dry run: NVMe partition is p1" "$(contains "${out}" "/dev/nvme1n1p1")" "${out}"
expect "setup dry run: apps move is queued for boot" "$(contains "${out}" "apps <new-uuid> /var/lib/flatpak")" "${out}"
expect "setup dry run: move does not touch fstab now" "$(lacks "${out}" "fstab (after")" "${out}"
out="$(tool setup nvme1n1 --role homes --name Homes --fs ext4 --erase --yes --dry-run)"
expect "homes: offered while /var/home is a subvolume on the system drive" "$(contains "${out}" "homes <new-uuid> /var/home")" "${out}"
out="$(FIXTURE="${ROOT}/tests/fixtures/sv-storage-lsblk-home-moved.json" tool setup nvme1n1 --role homes --name Homes --fs ext4 --erase --yes --dry-run)"
expect "homes: not offered once /var/home is on a drive of its own" "$(contains "${out}" "not possible")" "${out}"
out="$(FIXTURE="${ROOT}/tests/fixtures/sv-storage-lsblk-home-moved.json" tool list)"
expect "homes: the drive holding /var/home shows its role" "$(contains "$(grep -A1 '^  sdb ' <<<"${out}")" "/var/home")" "${out}"
out="$(SOURCE_BYTES=2000000000000 tool setup nvme1n1 --role apps --name Apps --fs ext4 --erase --yes --dry-run)"
expect "space: a move that does not fit is refused" "$(contains "${out}" "need about 2.2 TB, but this drive holds about 930 GB")" "${out}"
expect "space: refused before the drive is touched" "$(lacks "${out}" "would run")" "${out}"
expect "space: refusal exits 1" "$(contains "${out}" "rc=1")" "${out}"
out="$(SOURCE_BYTES=850000000000 tool setup nvme1n1 --role apps --name Apps --fs ext4 --erase --yes --dry-run)"
expect "space: just over the 10% margin is refused" "$(contains "${out}" "Choose a bigger drive")" "${out}"
out="$(SOURCE_BYTES=100000000000 tool setup nvme1n1 --role apps --name Apps --fs ext4 --erase --yes --dry-run)"
expect "space: a move that fits is queued" "$(contains "${out}" "apps <new-uuid> /var/lib/flatpak")" "${out}"
out="$(SOURCE_BYTES=2000000000000 tool setup sda --role storage --name Archive --fs ext4 --erase --yes --dry-run)"
expect "space: storage drives are not size-checked" "$(contains "${out}" "rc=0")" "${out}"
out="$(tool setup sdb --role storage --name Photos --keep --yes --dry-run)"
expect "setup dry run: keep mode does not wipe" "$(lacks "${out}" "wipefs")" "${out}"
expect "setup dry run: keep mode mounts the existing filesystem" "$(contains "${out}" "UUID=u-sdb1  /var/mnt/Photos")" "${out}"
expect "setup dry run: keep mode changes only the top folder" "$(lacks "${out}" "setfacl -R")" "${out}"
out="$(tool setup sdb --role apps --name Apps --fs exfat --erase --yes --dry-run)"
expect "setup: exFAT refused for apps" "$(contains "${out}" "cannot be used for apps")" "${out}"
out="$(tool setup sdd --role apps --name Apps --fs ext4 --erase --yes --dry-run)"
expect "setup: USB hard drive refused for apps" "$(contains "${out}" "not possible")" "${out}"
out="$(tool setup sdd --role storage --name Backup --fs ext4 --erase --yes --dry-run)"
expect "setup: USB hard drive (RM=0) allowed as storage" "$(contains "${out}" "rc=0")" "${out}"
expect "setup: external storage explains it must be plugged in" "$(contains "${out}" "whenever it is plugged in")" "${out}"
expect "setup: external storage stays nofail" "$(contains "${out}" "nofail")" "${out}"

out="$(tool usb sda --fs exfat --name USB --yes --dry-run)"
expect "usb: refuses an internal drive" "$(contains "${out}" "not a USB or removable drive")" "${out}"
out="$(tool usb nvme0n1 --fs exfat --name USB --yes --dry-run)"
expect "usb: refuses the system drive" "$(contains "${out}" "holds the system")" "${out}"
out="$(tool usb sdc --fs exfat --name "My Stick" --yes --dry-run)"
expect "usb dry run: unmounts through udisks" "$(contains "${out}" "would ask udisks to unmount /dev/sdc1")" "${out}"
expect "usb dry run: udisks wipes every signature first" "$(contains "${out}" "wipe every signature on /dev/sdc (Block.Format empty)")" "${out}"
expect "usb dry run: new MBR table through udisks" "$(contains "${out}" "new MBR table on /dev/sdc (Block.Format dos)")" "${out}"
expect "usb dry run: exFAT partition type 0x07 with its label" "$(contains "${out}" "type 0x07 and format it as exfat labelled My Stick")" "${out}"
expect "usb dry run: opens it in Files" "$(contains "${out}" "mount it so it opens in Files")" "${out}"
expect "usb dry run: never runs root tools" \
    "$(for c in wipefs sfdisk "dd if" mkfs pkexec sudo; do [[ "${out}" == *"${c}"* ]] && echo no && break; done; echo ok)" "${out}"
ADMIN=0
out="$(tool usb sdc --fs exfat --name USB --yes --dry-run)"
expect "usb: anyone may format a USB stick" "$(contains "${out}" "Block.Format empty")" "${out}"
expect "usb: no administrator refusal" "$(lacks "${out}" "needs an administrator")" "${out}"
out="$(tool setup sda --role storage --name X --fs ext4 --erase --yes --dry-run)"
expect "setup: refused to non-administrators" "$(contains "${out}" "Setting up drives needs an administrator account")" "${out}"
expect "setup: non-administrator exit code 77" "$(contains "${out}" "rc=77")" "${out}"
expect "setup: refused before any drive work" "$(lacks "${out}" "would run")" "${out}"
out="$(tool remove Media --yes --dry-run)"
expect "remove: refused to non-administrators" "$(contains "${out}" "rc=77")" "${out}"
out="$(tool cleanup --yes --dry-run)"
expect "cleanup: refused to non-administrators" "$(contains "${out}" "rc=77")" "${out}"
out="$(tool list)"
expect "list: open to everyone" "$(contains "${out}" "rc=0")" "${out}"
ADMIN=1
out="$(tool usb sdc --fs fat32 --name "my stick" --yes --dry-run)"
expect "usb dry run: FAT32 partition type 0x0c, label uppercased" "$(contains "${out}" "type 0x0c and format it as vfat labelled MY STICK")" "${out}"
expect "usb dry run: FAT 4 GB warning" "$(contains "${out}" "4 GB")" "${out}"
out="$(tool usb sdc --fs fat32 --name "much too long" --yes --dry-run)"
expect "usb: FAT name over 11 characters refused" "$(contains "${out}" "too long")" "${out}"
out="$(tool usb sdd --fs ext4 --name Backup --yes --dry-run)"
expect "usb: USB hard drive can be formatted" "$(contains "${out}" "format it as ext4 labelled Backup, owned by you")" "${out}"

out="$(tool remove Media --yes --dry-run)"
expect "remove dry run: removes the fstab entry" "$(contains "${out}" "UUID=u-media")" "${out}"
expect "remove dry run: erases nothing" "$(lacks "${out}" "wipefs")" "${out}"

# shellcheck source=/dev/null
source "${TOOL}"
names_ok=ok
for spec in "ext4:Sixteen chars OK" "xfs:Twelve chars" "exfat:Fifteen chars a" "ntfs:Thirty two characters exactly ab" "vfat:ELEVEN CHAR"; do
    validate_name "${spec%%:*}" "${spec#*:}" >/dev/null 2>&1 || names_ok="no (${spec})"
done
expect "names: longest valid label per filesystem accepted" "${names_ok}"
names_ok=ok
for spec in "ext4:Seventeen chars X" "xfs:Thirteen char" "exfat:Sixteen chars abc" "vfat:TWELVE CHARS" "ext4:" "ext4:bad/name" "ext4:-dash" "ext4:trailing "; do
    validate_name "${spec%%:*}" "${spec#*:}" >/dev/null 2>&1 && names_ok="no (${spec})"
done
expect "names: too long or bad labels refused" "${names_ok}"
expect "names: FAT uppercased" "$( [[ "$(validate_name vfat photos)" == PHOTOS ]] && echo ok)"
expect "fstab: NTFS uses the kernel driver and owner options" \
    "$(contains "$(render_fstab_entry U /var/mnt/Win ntfs "$(mount_options ntfs storage Win 1000 10)" storage Win)" \
        "UUID=U  /var/mnt/Win  ntfs3  defaults,nofail,x-systemd.device-timeout=10s,uid=1000,gid=10,umask=0002,x-gvfs-show,x-gvfs-name=Win  0  0")"
expect "fstab: moved folders are ordered before local-fs.target" \
    "$(contains "$(mount_options ext4 homes "" 0 0)" "x-systemd.before=local-fs.target")"
expect "fstab: escaping round-trips" "$( [[ "$(fstab_unescape "$(fstab_escape "My Media")")" == "My Media" ]] && echo ok)"
expect "space: the real computer is never measured with a fixture" \
    "$( [[ "$(SV_STORAGE_LSBLK_JSON=x role_bytes /)" == 0 ]] && echo ok)"
printf '%s\n' "UUID=u-root / btrfs subvol=root,ro 0 0" "UUID=u-root /home btrfs subvol=home,compress=zstd:1 0 0" \
    "UUID=u-root /var btrfs subvol=var 0 0" > "${WORK}/fstab-atomic"
expect "subvolume: finds the installer's /home line for /var/home" \
    "$( [[ "$(SV_STORAGE_FSTAB="${WORK}/fstab-atomic" bash -c 'source "$1"; fstab_line_for /var/home' _ "${TOOL}")" == 2 ]] && echo ok)"
expect "subvolume: no line for a folder fstab does not mount" \
    "$( [[ -z "$(SV_STORAGE_FSTAB="${WORK}/fstab-atomic" bash -c 'source "$1"; fstab_line_for /var/lib/flatpak' _ "${TOOL}")" ]] && echo ok)"
expect "size: decimal units" "$( [[ "$(human_size 500107862016)" == "500 GB" && "$(human_size 31004295168)" == "31 GB" ]] && echo ok)"

echo
echo "${PASSED} passed, ${FAILED} failed"
(( FAILED == 0 ))
