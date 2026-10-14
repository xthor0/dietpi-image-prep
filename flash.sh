#!/usr/bin/env bash
# Write a prepared image to an SD card / USB disk, then verify it. Linux only.
# Lists removable/USB disks only, never offers the disk holding / and requires typing the device.
set -euo pipefail

image=""
dev=""
yes=0

log()  { printf '==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<USAGE
Usage: $0 -i image.img [-d /dev/sdX] [-y]
  -i  image to write
  -d  target disk (omit to pick from a list of removable/USB disks)
  -y  skip the typed confirmation (requires -d)
USAGE
  exit 1
}

while getopts "i:d:yh" opt; do
  case $opt in
    i) image=$OPTARG ;;
    d) dev=$OPTARG ;;
    y) yes=1 ;;
    *) usage ;;
  esac
done
[ -n "$image" ] || usage
[ "$yes" = 0 ] || [ -n "$dev" ] || die "-y requires an explicit -d"
[ "$(uname -s)" = Linux ] || die "Linux only; on macOS use Raspberry Pi Imager/Etcher, or dd to /dev/rdiskN by hand"
[ -r "$image" ] || die "cannot read image: $image"
if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi
for c in lsblk dd cmp findmnt blockdev; do command -v "$c" >/dev/null || die "missing command: $c"; done

# Whole disks that hold the running system (/ and /boot*): never targets.
sysdisks=""
for m in / /boot /boot/efi; do
  src=$(findmnt -no SOURCE "$m" 2>/dev/null || true)
  [ -n "$src" ] || continue
  pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1 || true)
  [ -n "$pk" ] && sysdisks="$sysdisks /dev/$pk"
done

is_sysdisk() { case " $sysdisks " in *" $1 "*) return 0 ;; esac; return 1; }

if [ -z "$dev" ]; then
  log "removable / USB disks:"
  cands=()
  while read -r line; do
    eval "$line"   # lsblk -P emits KEY="value" pairs, already escaped
    [ "$TYPE" = disk ] && [ "$SIZE" != "0B" ] || continue
    is_sysdisk "$NAME" && continue
    if [ "$RM" = 1 ] || [ "$TRAN" = usb ]; then
      cands+=("$NAME")
      printf '  %-12s %-8s %-5s %s\n' "$NAME" "$SIZE" "${TRAN:--}" "$MODEL"
    fi
  done < <(lsblk -dnpP -o NAME,SIZE,TRAN,RM,MODEL,TYPE)
  [ "${#cands[@]}" -gt 0 ] || die "no removable/USB disks found"
  read -r -p "Target device (type the full path): " dev
fi

[ -b "$dev" ] || die "$dev is not a block device"
case "$(lsblk -dno TYPE "$dev")" in
  disk|loop) ;;   # loop only when named explicitly with -d (handy for testing)
  *) die "$dev is not a whole disk" ;;
esac
is_sysdisk "$dev" && die "$dev holds the running system"
mounted=$(lsblk -nro MOUNTPOINTS "$dev" | grep -v '^$' || true)
[ -z "$mounted" ] || die "$dev has mounted filesystems ($mounted); unmount them first"

imgsize=$(stat -c %s "$image")
devsize=$(blockdev --getsize64 "$dev")
[ "$devsize" -ge "$imgsize" ] || die "$dev ($devsize bytes) is smaller than the image ($imgsize bytes)"

lsblk -o NAME,SIZE,TRAN,MODEL,FSTYPE,LABEL "$dev"
if [ "$yes" != 1 ]; then
  echo "This ERASES everything on $dev."
  read -r -p "Type the device path again to confirm: " again
  [ "$again" = "$dev" ] || die "confirmation did not match; nothing written"
fi

log "writing $image to $dev"
dd if="$image" of="$dev" bs=4M conv=fsync status=progress
sync
partprobe "$dev" 2>/dev/null || true
log "verifying"
cmp -n "$imgsize" "$image" "$dev" && log "verified: $dev matches $image"
