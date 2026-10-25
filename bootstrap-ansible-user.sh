#!/usr/bin/env bash
set -Eeuo pipefail

# Bootstrap an Ansible account on Debian-based systems.
# Usage: sudo ./bootstrap-ansible-user.sh username=sysadmin password='change-me'
readonly SCRIPT_NAME="\${0##*/}"
log() { printf '[%s] %s\n' "$SCRIPT_NAME" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

username=''
password=''
public_key=''
for argument in "$@"; do
  case "$argument" in
    username=*) username="\${argument#username=}" ;;
    password=*) password="\${argument#password=}" ;;
    ssh_public_key=*) public_key="\${argument#ssh_public_key=}" ;;
    *) die "Unknown argument: $argument (use username=..., password=..., ssh_public_key=...)" ;;
  esac
done

[[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Pass a valid username using username=... (lowercase letters, digits, _ and -)."
[[ -n "$password" ]] || die "Pass a non-empty password using password=...."
[[ "$password" != *:* ]] || die "The password must not contain a colon."
if [[ -n "$public_key" ]]; then
  case "$public_key" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-nistp256\ *|ecdsa-sha2-nistp384\ *|ecdsa-sha2-nistp521\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-nistp256@openssh.com\ *) ;;
    *) die "The supplied key does not look like a supported SSH public key." ;;
  esac
fi

[[ -r /etc/os-release ]] || die "Cannot identify OS: /etc/os-release is missing."
command -v apt-get >/dev/null 2>&1 || die "This script supports Debian-based systems that use apt-get."
. /etc/os-release
os_id="\${ID,,}"
os_like="\${ID_LIKE,,}"
case "$os_id" in
  debian|ubuntu|raspbian|dietpi) ;;
  *)
    case " $os_like " in
      *" debian "*|*" ubuntu "*) ;;
      *) die "Unsupported distribution: \${PRETTY_NAME:-$os_id}. Supported: Debian, Ubuntu, Raspberry Pi OS, DietPi." ;;
    esac
    ;;
esac

if [[ $EUID -eq 0 ]]; then
  PRIVILEGE_PREFIX=()
elif command -v sudo >/dev/null 2>&1; then
  PRIVILEGE_PREFIX=(sudo)
else
  die "Run this script as root, or install sudo and run it with sudo."
fi
run_privileged() { "\${PRIVILEGE_PREFIX[@]}" "$@"; }

log "Detected OS: \${PRETTY_NAME:-$os_id}"
log "Installing required packages (sudo, OpenSSH server, Python 3)..."
export DEBIAN_FRONTEND=noninteractive
run_privileged apt-get update
run_privileged apt-get install -y sudo openssh-server python3

if ! getent passwd "$username" >/dev/null; then
  run_privileged useradd --create-home --user-group --shell /bin/bash "$username"
  log "Created user: $username"
else
  log "User already exists; preserving its home directory, shell, and group memberships."
fi

# Send the password through stdin rather than a child process argument or shell history.
printf '%s:%s\n' "$username" "$password" | run_privileged chpasswd
unset password

run_privileged install -d -m 0750 /etc/sudoers.d
sudoers_tmp="$(run_privileged mktemp /etc/sudoers.d/.ansible-bootstrap.XXXXXX)"
trap 'if [[ -n "\${sudoers_tmp:-}" ]]; then run_privileged rm -f -- "$sudoers_tmp"; fi' EXIT
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$username" | run_privileged tee "$sudoers_tmp" >/dev/null
run_privileged chmod 0440 "$sudoers_tmp"
run_privileged visudo -cf "$sudoers_tmp" >/dev/null || die "sudoers syntax validation failed."
run_privileged install -o root -g root -m 0440 "$sudoers_tmp" "/etc/sudoers.d/ansible-$username"
run_privileged rm -f "$sudoers_tmp"
sudoers_tmp=''

if [[ -n "$public_key" ]]; then
  user_home="$(getent passwd "$username" | cut -d: -f6)"
  user_group="$(id -gn "$username")"
  [[ -n "$user_home" && -d "$user_home" ]] || die "Cannot determine the home directory for $username."
  run_privileged install -d -m 0700 -o "$username" -g "$user_group" "$user_home/.ssh"
  authorized_keys="$user_home/.ssh/authorized_keys"
  run_privileged touch "$authorized_keys"
  run_privileged chmod 0600 "$authorized_keys"
  run_privileged chown "$username:$user_group" "$authorized_keys"
  if ! run_privileged grep -Fqx -- "$public_key" "$authorized_keys"; then
    printf '%s\n' "$public_key" | run_privileged tee -a "$authorized_keys" >/dev/null
  fi
  log "Installed SSH public key for $username."
fi
unset public_key

if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
    run_privileged systemctl enable --now ssh
  else
    run_privileged systemctl enable --now sshd
  fi
elif command -v update-rc.d >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
  run_privileged update-rc.d ssh defaults
  run_privileged service ssh start
else
  die "Cannot enable SSH at boot: no supported service manager was found."
fi

log "Bootstrap completed. OpenSSH is installed, enabled at boot, and running."
log "Python 3 and sudo are installed; $username has passwordless sudo."
log "Test: ssh $username@<host> ; privilege escalation: ssh $username@<host> 'sudo -n whoami'"
