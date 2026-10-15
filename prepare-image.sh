#!/usr/bin/env bash
# Take a stock DietPi image, bake in first-boot settings, and write a ready-to-flash .img.
# Linux only (loop-mounts the image's ext4 root partition). Re-runs itself under sudo.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
config="$here/config.env"
image=""
host_name=""
static_ip=""
out=""
force=0

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: $0 -n HOSTNAME -i DietPi_<board>.img.xz [-a IP[/CIDR]] [-c config.env] [-o output.img] [-f]
  -n  hostname for this board (required; changes per card, so it is not in config.env)
  -a  static IPv4 address for this board, e.g. 192.168.1.20/24 (default /24; omit for DHCP).
      The gateway defaults to the first host address of the subnet (x.x.x.1) and DNS defaults to
      the gateway; set STATIC_GATEWAY / STATIC_DNS in config.env to override
  -i  stock DietPi image (.img.xz or .img)
  -c  settings file (default: $here/config.env; copy config.env.example)
  -o  output image (default: ./<input name>-prepared.img)
  -f  overwrite the output if it exists
USAGE
  exit 1
}

while getopts "n:a:i:c:o:fh" opt; do
  case $opt in
    n) host_name=$OPTARG ;;
    a) static_ip=$OPTARG ;;
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
APT_INSTALLS=${APT_INSTALLS:-python3 python3-apt sudo}
UNMASK_LOGIND=${UNMASK_LOGIND:-1}
SSH_SERVER_INDEX=${SSH_SERVER_INDEX:--2}
WIFI_ENABLED=${WIFI_ENABLED:-0}
WIFI_SSID=${WIFI_SSID:-}
WIFI_KEY=${WIFI_KEY:-}
WIFI_KEYMGR=${WIFI_KEYMGR:-WPA-PSK}
WIFI_COUNTRY=${WIFI_COUNTRY:-US}
IMAGE_SHA256=${IMAGE_SHA256:-}
STATIC_GATEWAY=${STATIC_GATEWAY:-}
STATIC_DNS=${STATIC_DNS:-}

# dotted quad -> integer; valid_ipv4 rejects anything that is not four octets of 0-255
valid_ipv4() {
  local o IFS=.
  [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  for o in $1; do [ "$((10#$o))" -le 255 ] || return 1; done
}
int_to_ip() { echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"; }
ip_to_int() { local IFS=. o; read -ra o <<< "$1"; echo $(( (10#${o[0]} << 24) + (10#${o[1]} << 16) + (10#${o[2]} << 8) + 10#${o[3]} )); }

if [ -n "$static_ip" ]; then
  ip=${static_ip%/*}
  cidr=24
  [[ $static_ip == */* ]] && cidr=${static_ip#*/}
  valid_ipv4 "$ip" || die "-a: '$ip' is not a valid IPv4 address"
  [[ $cidr =~ ^[0-9]+$ ]] && [ "$cidr" -ge 8 ] && [ "$cidr" -le 30 ] || die "-a: prefix length '$cidr' must be 8-30"
  mask=$(( (0xFFFFFFFF << (32 - cidr)) & 0xFFFFFFFF ))
  addr=$(ip_to_int "$ip"); net=$(( addr & mask )); bcast=$(( net | (~mask & 0xFFFFFFFF) ))
  [ "$addr" -ne "$net" ] && [ "$addr" -ne "$bcast" ] || die "-a: $ip is the network or broadcast address of /$cidr"
  # no gateway configured: use the first host address of the subnet (x.x.x.1)
  if [ -z "$STATIC_GATEWAY" ]; then
    STATIC_GATEWAY=$(int_to_ip $(( net + 1 )))
    [ "$STATIC_GATEWAY" != "$ip" ] || die "-a: $ip is the default gateway ($STATIC_GATEWAY) of that subnet; set STATIC_GATEWAY in $config"
  fi
  valid_ipv4 "$STATIC_GATEWAY" || die "STATIC_GATEWAY '$STATIC_GATEWAY' is not a valid IPv4 address"
  [ "$ip" != "$STATIC_GATEWAY" ] || die "-a: the address is the same as the gateway"
  [ $(( $(ip_to_int "$STATIC_GATEWAY") & mask )) -eq "$net" ] || die "STATIC_GATEWAY $STATIC_GATEWAY is not inside $ip/$cidr"
  dns=$(tr ',' ' ' <<< "${STATIC_DNS:-$STATIC_GATEWAY}" | xargs)
  for d in $dns; do valid_ipv4 "$d" || die "STATIC_DNS entry '$d' is not a valid IPv4 address"; done
fi

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
if [ -n "$static_ip" ]; then
  set_kv "$txt" AUTO_SETUP_NET_USESTATIC 1
  set_kv "$txt" AUTO_SETUP_NET_STATIC_IP "$ip/$cidr"
  set_kv "$txt" AUTO_SETUP_NET_STATIC_GATEWAY "$STATIC_GATEWAY"
  set_kv "$txt" AUTO_SETUP_NET_STATIC_DNS "$dns"
fi
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
