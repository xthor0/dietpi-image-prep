#!/usr/bin/env bash
# Take a stock DietPi image, bake in first-boot settings, and write a ready-to-flash .img.
# Linux only (loop-mounts the image's ext4 root partition). Re-runs itself under sudo.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
config="$here/config.env"
image=""
host_name=""
out=""
force=0

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: $0 -n HOSTNAME -i DietPi_<board>.img.xz [-c config.env] [-o output.img] [-f]
  -n  hostname for this board (required; changes per card, so it is not in config.env)
  -i  stock DietPi image (.img.xz or .img)
  -c  settings file (default: $here/config.env; copy config.env.example)
  -o  output image (default: ./<input name>-prepared.img)
  -f  overwrite the output if it exists
USAGE
  exit 1
}

while getopts "n:i:c:o:fh" opt; do
  case $opt in
    n) host_name=$OPTARG ;;
    i) image=$OPTARG ;;
    c) config=$OPTARG ;;
    o) out=$OPTARG ;;
    f) force=1 ;;
    *) usage ;;
  esac
done
[ -n "$host_name" ] || { echo "ERROR: -n HOSTNAME is required" >&2; usage; }
[ -n "$image" ] || usage
[[ "$host_name" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die "invalid hostname '$host_name' (letters, digits and hyphens; no dots, no leading/trailing hyphen)"
[ "$(uname -s)" = Linux ] || die "Linux only (needs loop devices and ext4 write support)"
[ -r "$image" ]  || die "cannot read image: $image"
[ -r "$config" ] || die "cannot read config: $config (copy config.env.example to config.env)"

if [ "$EUID" -ne 0 ]; then
  exec sudo "$0" "$@"
fi
for c in xz losetup mount umount awk sha256sum mktemp; do
  command -v "$c" >/dev/null || die "missing command: $c"
done

# shellcheck disable=SC1090
. "$config"
TIMEZONE=${TIMEZONE:-UTC}
KEYBOARD_LAYOUT=${KEYBOARD_LAYOUT:-us}
PASSWORD=${PASSWORD:-p@ssw0rd}
USERNAME=${USERNAME:-}
SSH_KEY_URLS=${SSH_KEY_URLS:-}
SUDO_NOPASSWD=${SUDO_NOPASSWD:-1}
APT_INSTALLS=${APT_INSTALLS:-python3 sudo}
UNMASK_LOGIND=${UNMASK_LOGIND:-1}
SSH_SERVER_INDEX=${SSH_SERVER_INDEX:--2}
WIFI_ENABLED=${WIFI_ENABLED:-0}
WIFI_SSID=${WIFI_SSID:-}
WIFI_KEY=${WIFI_KEY:-}
WIFI_KEYMGR=${WIFI_KEYMGR:-WPA-PSK}
WIFI_COUNTRY=${WIFI_COUNTRY:-US}
IMAGE_SHA256=${IMAGE_SHA256:-}

if [ -n "$USERNAME" ] && [ -z "$SSH_KEY_URLS" ]; then
  die "USERNAME is set but SSH_KEY_URLS is empty; set at least one URL or clear USERNAME"
fi
if [ "$WIFI_ENABLED" = 1 ]; then
  [ -n "$WIFI_SSID" ] || die "WIFI_ENABLED=1 needs WIFI_SSID"
  case "$WIFI_KEYMGR" in
    NONE) ;;
    WPA-PSK|WEP) [ -n "$WIFI_KEY" ] || die "WIFI_KEYMGR=$WIFI_KEYMGR needs WIFI_KEY" ;;
    *) die "WIFI_KEYMGR must be NONE, WPA-PSK or WEP" ;;
  esac
  warn "Wi-Fi on: DietPi disables Ethernet. Make sure this board's Wi-Fi driver works before relying on it."
fi
[ "$PASSWORD" != "p@ssw0rd" ] || warn "using the default throwaway password; change it once the board is up"

if [ -n "$IMAGE_SHA256" ]; then
  log "verifying SHA-256"
  actual=$(sha256sum "$image" | awk '{print $1}')
  [ "$actual" = "$IMAGE_SHA256" ] || die "SHA-256 mismatch: expected $IMAGE_SHA256, got $actual"
else
  warn "IMAGE_SHA256 not set; the download is not verified"
fi

if [ -z "$out" ]; then
  base=$(basename "$image"); base=${base%.xz}; base=${base%.img}
  out="$PWD/${base}-${host_name}.img"
fi
if [ -e "$out" ] && [ "$force" != 1 ]; then die "$out exists (use -f to overwrite)"; fi

loop=""
mnt=""
cleanup() {
  set +e
  if [ -n "$mnt" ] && mountpoint -q "$mnt"; then umount "$mnt"; fi
  [ -n "$mnt" ] && rmdir "$mnt" 2>/dev/null
  [ -n "$loop" ] && losetup -d "$loop"
}
trap cleanup EXIT

log "writing working image: $out"
case "$image" in
  *.xz) xz -dc "$image" > "$out" ;;
  *.img) cp "$image" "$out" ;;
  *) die "unsupported image type (want .img.xz or .img)" ;;
esac

# Replace the first line starting with $2 (a prefix like "KEY=") by $3, or append $3 if none.
replace_line() {
  local file=$1 prefix=$2 line=$3 tmp
  tmp=$(mktemp)
  PREFIX=$prefix LINE=$line awk '
    BEGIN { p = ENVIRON["PREFIX"]; l = ENVIRON["LINE"]; done = 0 }
    !done && index($0, p) == 1 { print l; done = 1; next }
    { print }
    END { if (!done) print l }' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}
set_kv()   { replace_line "$1" "$2=" "$2=$3"; }
# dietpi-wifi.txt values are single-quoted; a literal ' becomes '\''
sq()       { printf '%s' "${1//\'/\'\\\'\'}"; }
set_wifi() { replace_line "$1" "$2=" "$2='$(sq "$3")'"; }

log "attaching and mounting"
loop=$(losetup -fP --show "$out")
udevadm settle 2>/dev/null || sleep 1
mnt=$(mktemp -d)
bootdir=""
for part in "${loop}"p*; do
  [ -b "$part" ] || continue
  if mount "$part" "$mnt" 2>/dev/null; then
    if [ -f "$mnt/boot/dietpi.txt" ]; then bootdir="$mnt/boot"; break; fi
    if [ -f "$mnt/dietpi.txt" ];      then bootdir="$mnt";      break; fi
    umount "$mnt"
  fi
done
[ -n "$bootdir" ] || die "no partition with dietpi.txt found (is this a DietPi image?)"
log "found dietpi.txt in ${bootdir#"$mnt"}"

txt="$bootdir/dietpi.txt"
set_kv "$txt" AUTO_SETUP_AUTOMATED 1
set_kv "$txt" AUTO_SETUP_GLOBAL_PASSWORD "$PASSWORD"
set_kv "$txt" AUTO_SETUP_KEYBOARD_LAYOUT "$KEYBOARD_LAYOUT"
set_kv "$txt" AUTO_SETUP_TIMEZONE "$TIMEZONE"
set_kv "$txt" AUTO_SETUP_NET_HOSTNAME "$host_name"
set_kv "$txt" AUTO_SETUP_SSH_SERVER_INDEX "$SSH_SERVER_INDEX"
set_kv "$txt" AUTO_UNMASK_LOGIND "$UNMASK_LOGIND"
[ -z "$APT_INSTALLS" ] || set_kv "$txt" AUTO_SETUP_APT_INSTALLS "$APT_INSTALLS"

if [ "$WIFI_ENABLED" = 1 ]; then
  set_kv "$txt" AUTO_SETUP_NET_WIFI_ENABLED 1
  set_kv "$txt" AUTO_SETUP_NET_WIFI_COUNTRY_CODE "$WIFI_COUNTRY"
  wifi="$bootdir/dietpi-wifi.txt"
  [ -f "$wifi" ] || die "dietpi-wifi.txt missing from the image"
  set_wifi "$wifi" 'aWIFI_SSID[0]'   "$WIFI_SSID"
  set_wifi "$wifi" 'aWIFI_KEY[0]'    "$WIFI_KEY"
  set_wifi "$wifi" 'aWIFI_KEYMGR[0]' "$WIFI_KEYMGR"
  chmod 600 "$wifi"
fi

if [ -n "$USERNAME" ]; then
  # Hook is /boot/Automation_Custom_Script.sh (AUTO_SETUP_CUSTOM_SCRIPT_EXEC=0, the stock default).
  install -m 0755 "$here/templates/Automation_Custom_Script.sh" "$bootdir/Automation_Custom_Script.sh"
  envf="$bootdir/Automation_Custom_Script.env"
  : > "$envf"; chmod 600 "$envf"
  {
    printf 'USERNAME=%q\n' "$USERNAME"
    printf 'PASSWORD=%q\n' "$PASSWORD"
    printf 'SSH_KEY_URLS=%q\n' "$SSH_KEY_URLS"
    printf 'SUDO_NOPASSWD=%q\n' "$SUDO_NOPASSWD"
  } > "$envf"
  set_kv "$txt" AUTO_SETUP_CUSTOM_SCRIPT_EXEC 0
fi

sync
umount "$mnt"
losetup -d "$loop"; loop=""
rmdir "$mnt"; mnt=""
trap - EXIT
log "done: $out"
log "next: ./flash.sh -i $out"
