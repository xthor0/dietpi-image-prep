#!/bin/bash
# Runs once as root on DietPi's first boot, after the network is up and the first-run install is
# done (see AUTO_SETUP_CUSTOM_SCRIPT_EXEC=0 in dietpi.txt). Settings come from
# /boot/Automation_Custom_Script.env, written by prepare-image.sh.
set -u
log() { logger -t custom-script "$*"; echo "custom-script: $*"; }

env_file=/boot/Automation_Custom_Script.env
[ -r "$env_file" ] || { log "$env_file missing; nothing to do"; exit 0; }
# shellcheck disable=SC1090
. "$env_file"

[ -n "${USERNAME:-}" ] || { log "no USERNAME set; skipping user and key setup"; rm -f "$env_file"; exit 0; }

if ! id "$USERNAME" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$USERNAME" || { log "useradd $USERNAME failed"; exit 1; }
fi
echo "$USERNAME:$PASSWORD" | chpasswd
if command -v sudo >/dev/null 2>&1; then
  usermod -aG sudo "$USERNAME"
  if [ "${SUDO_NOPASSWD:-0}" = 1 ]; then
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"
    chmod 0440 "/etc/sudoers.d/$USERNAME"
  fi
else
  log "sudo not installed; skipped sudo setup"
fi

home=$(getent passwd "$USERNAME" | cut -d: -f6)
install -d -o "$USERNAME" -g "$USERNAME" -m 0700 "$home/.ssh"
t="$home/.ssh/authorized_keys.new"

# Accept a download only if it is non-empty, bare public keys, all parsed by ssh-keygen.
fetch() {
  rm -f "$t"
  curl -fsSL --max-time 15 --retry 2 --retry-delay 3 "$1" -o "$t" || return 1
  n=$(grep -cvE '^[[:space:]]*$' "$t")
  [ "$n" -ge 1 ] || return 1
  if grep -vE '^[[:space:]]*$' "$t" | grep -qvE '^(ssh-|ecdsa-|sk-)'; then return 1; fi
  [ "$(ssh-keygen -l -f "$t" 2>/dev/null | wc -l)" -eq "$n" ]
}

ok=0
for url in ${SSH_KEY_URLS:-}; do
  if fetch "$url"; then ok=1; log "keys from $url"; break; fi
  log "no valid keys from $url"
done

if [ "$ok" = 1 ]; then
  mv "$t" "$home/.ssh/authorized_keys"
  chown "$USERNAME:$USERNAME" "$home/.ssh/authorized_keys"
  chmod 0600 "$home/.ssh/authorized_keys"
  log "installed $(wc -l < "$home/.ssh/authorized_keys") keys for $USERNAME"
  rm -f "$env_file"   # holds the plaintext password
else
  rm -f "$t"
  if [ -n "${SSH_KEY_URLS:-}" ]; then
    log "no valid SSH keys from any of: $SSH_KEY_URLS"
    touch /root/KEYS_FETCH_FAILED
    exit 1
  fi
  log "SSH_KEY_URLS empty; no keys installed"
  rm -f "$env_file"
fi
