# dietpi-image-prep

Turn a stock [DietPi](https://dietpi.com/) image into a ready-to-flash image that boots, joins the network (Ethernet or Wi-Fi), creates your login user, and installs your SSH keys on first boot with no keyboard or screen. Built for headless single-board computers (developed against the Orange Pi Zero 3), but it only touches DietPi's own first-boot files, so it should work with any DietPi image that ships `dietpi.txt`.

- `prepare-image.sh` unpacks the image, edits `dietpi.txt` (and `dietpi-wifi.txt`), and installs a first-boot script.
- `flash.sh` writes the result to an SD card or USB disk and verifies it.
- Both are Linux only: they loop-mount the image's ext4 root partition, which macOS cannot do. Run them on any Linux box (a VM works).

## Quick start

```sh
cp config.env.example config.env
$EDITOR config.env                # at least USERNAME and SSH_KEY_URLS
./prepare-image.sh -n myboard -i DietPi_OrangePiZero3-ARMv8-Trixie.img.xz
./flash.sh -i DietPi_OrangePiZero3-ARMv8-Trixie-myboard.img
```

Put the card in the board, power it on, and wait a few minutes. DietPi resizes the filesystem, installs OpenSSH, runs apt, and reboots by itself. Then `ssh <USERNAME>@<hostname or its IP>`.

Set `IMAGE_SHA256` in `config.env` to the checksum published on the DietPi download page, otherwise the download is not verified.

## What it does to the image

| Setting (`config.env`) | Effect |
|---|---|
| always | `AUTO_SETUP_AUTOMATED=1`, so first boot needs no input |
| `-n HOSTNAME` (command line, required) | `AUTO_SETUP_NET_HOSTNAME`; it changes per card, so it is an argument and not in `config.env` |
| `TIMEZONE`, `KEYBOARD_LAYOUT`, `PASSWORD` | the matching `AUTO_SETUP_*` values in `dietpi.txt` (`PASSWORD` is DietPi's global password for root and the `dietpi` user) |
| `SSH_SERVER_INDEX=-2` | OpenSSH instead of DietPi's default Dropbear (needed for `sshd_config.d`, `sshd -T`, and most Ansible roles) |
| `UNMASK_LOGIND=1` | `AUTO_UNMASK_LOGIND=1`, since DietPi masks logind and ships no dbus, which breaks `hostnamectl`/`timedatectl` and Ansible's `hostname` and `timezone` modules |
| `APT_INSTALLS="python3 sudo"` | `AUTO_SETUP_APT_INSTALLS`; DietPi has no python3 and Ansible needs it |
| `USERNAME`, `SSH_KEY_URLS`, `SUDO_NOPASSWD` | installs `/boot/Automation_Custom_Script.sh`, which creates the user, optionally gives passwordless sudo, and installs keys from the first URL that returns only valid public keys |
| `WIFI_*` | enables Wi-Fi in `dietpi.txt` and fills entry 0 of `dietpi-wifi.txt` |

The key fetch accepts a download only if it is non-empty, every line is a bare public key (`ssh-`, `ecdsa-`, `sk-`; no `command=` options), and `ssh-keygen` parses every line. If every URL fails, the script exits non-zero and leaves `/root/KEYS_FETCH_FAILED`. Password login stays on, so the board is still recoverable.

## Wi-Fi

Set `WIFI_ENABLED=1`, `WIFI_SSID`, `WIFI_KEY`, and `WIFI_COUNTRY`. `config.env` is a shell file, so quote values; single quotes are safest (`WIFI_KEY='p@ss $word'`). The script handles quotes inside values when it writes DietPi's files.

- DietPi disables Ethernet when Wi-Fi is enabled. If the board's Wi-Fi driver does not work you will have no network at all. Test Wi-Fi on a spare card before depending on it.
- Only WPA-PSK, WEP, and open networks are supported (no WPA-EAP).
- The Orange Pi Zero 3's Wi-Fi chip (Unisoc UWE5622) needs an out-of-tree driver. That it works on DietPi's kernel is **untested here**.

## Security notes

- Everything is written to the card in plaintext: the password in `dietpi.txt`, the Wi-Fi key in `dietpi-wifi.txt` (mode 600). The custom script deletes its own settings file after a successful run. Treat `PASSWORD` as a throwaway and replace it (Ansible, `passwd`) after first boot.
- Do not commit `config.env`. It is gitignored.
- `flash.sh` lists only removable/USB disks, never offers the disk holding `/`, `/boot`, or `/boot/efi`, refuses mounted or too-small targets, and asks you to retype the device path. `-y` skips the retype and requires `-d`.

## Verified and not verified

Tested on a Debian 13 x86_64 host against `DietPi_OrangePiZero3-ARMv8-Trixie.img.xz` (DietPi 10.7.2):

- `prepare-image.sh` runs, every `dietpi.txt` and `dietpi-wifi.txt` setting is written, and a Wi-Fi SSID and key containing quotes, `$`, `&`, `|` and a trailing backslash round-trip exactly.
- `flash.sh` writes and verifies, and refuses the system disk, undersized targets, a wrong confirmation, and `-y` without `-d` (tested against loop devices, not a real card).
- An earlier hand-made card with the same settings booted unattended, created the user, installed OpenSSH, and installed validated keys.

Not tested:

- A boot of an image produced by these scripts. Specifically `AUTO_UNMASK_LOGIND=1` installing dbus and `libpam-systemd`, and `AUTO_SETUP_APT_INSTALLS` (appended to the end of `dietpi.txt`) being honored.
- Wi-Fi on first boot.
- Boards whose boot files live on a separate FAT partition (the script looks for `dietpi.txt` in `/boot` of each partition and at the partition root).

## Gotcha: DietPi masks the apt timers

DietPi masks `apt-daily.timer` and `apt-daily-upgrade.timer`, so `unattended-upgrades` installed later never runs by itself. If you want automatic updates, unmask them after first boot. This tool does not touch them.

## License

MIT. See `LICENSE`.
