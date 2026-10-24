#!/usr/bin/env bash
set -Eeuo pipefail

# Bootstrap a dedicated account for Ansible on supported Debian-based systems.
# Intended to be run as root, including via: curl ... | sudo bash

readonly SCRIPT_NAME="${0##*/}"
readonly SUDOERS_DIR="/etc/sudoers.d"

# If sudo exists, use it for privileged operations. On minimal systems such as
# Proxmox VE, where sudo is absent, execute commands directly as root.
if command -v sudo >/dev/null 2>&1; then
  PRIVILEGE_PREFIX=(sudo)
  HAS_SUDO=true
else
  PRIVILEGE_PREFIX=()
  HAS_SUDO=false
fi

run_privileged() {
  "${PRIVILEGE_PREFIX[@]}" "$@"
}

log() { printf '[%s] %s\n' "$SCRIPT_NAME" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

if [[ "$HAS_SUDO" == false && $EUID -ne 0 ]]; then
  die "sudo is not installed. Run this script as root on this system."
fi
[[ -r /etc/os-release ]] || die "Cannot identify OS: /etc/os-release is missing."
command -v apt-get >/dev/null 2>&1 || die "This script supports Debian-based systems that use apt-get."

# Interactive input must come from the terminal because stdin may contain this script.
[[ -r /dev/tty && -w /dev/tty ]] || die "An interactive terminal is required."
exec 3<>/dev/tty

. /etc/os-release
os_id="${ID,,}"
os_like="${ID_LIKE,,}"
case "$os_id" in
  debian|ubuntu|raspbian|dietpi) ;;
  *)
    case " $os_like " in
      *" debian "*|*" ubuntu "*) ;;
      *) die "Unsupported distribution: ${PRETTY_NAME:-$os_id}. Supported: Debian, Ubuntu, Raspberry Pi OS, DietPi." ;;
    esac
    ;;
esac

log "Detected OS: ${PRETTY_NAME:-$os_id}"
printf 'Dedicated Ansible account username: ' >&3
IFS= read -r username <&3
[[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid username. Use lowercase Linux account characters (letters, digits, _ and -)."

while :; do
  printf 'Password for user %s: ' "$username" >&3
  IFS= read -r -s password <&3
  printf '\nConfirm password: ' >&3
  IFS= read -r -s password_confirm <&3
  printf '\n' >&3
  [[ -n "$password" ]] || { log "Password cannot be empty; try again."; continue; }
  [[ "$password" != *:* ]] || { log "Password must not contain a colon; try again."; continue; }
  [[ "$password" == "$password_confirm" ]] && break
  log "Passwords do not match; try again."
done
unset password_confirm

if [[ "$HAS_SUDO" == true ]]; then
  configure_sudo=true
  log "sudo detected; passwordless sudo will be configured for the account."
else
  configure_sudo=false
  log "sudo not found; privileged commands will run directly (run this script as root)."
fi

printf 'Optional: paste one SSH public key for this account (press Enter to skip):\n> ' >&3
IFS= read -r public_key <&3
if [[ -n "$public_key" ]]; then
  case "$public_key" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-nistp256\ *|ecdsa-sha2-nistp384\ *|ecdsa-sha2-nistp521\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-nistp256@openssh.com\ *) ;;
    *) die "The supplied key does not look like a supported SSH public key." ;;
  esac
fi

log "Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
run_privileged apt-get update
run_privileged apt-get install -y openssh-server python3

if ! getent passwd "$username" >/dev/null; then
  run_privileged useradd --create-home --user-group --shell /bin/bash "$username"
  log "Created user: $username"
else
  log "User already exists; preserving its existing home directory, shell, and group memberships."
fi

# Set the account password without placing it in command-line arguments or shell history.
printf '%s:%s\n' "$username" "$password" | run_privileged chpasswd
unset password

if [[ "$configure_sudo" == true ]]; then
  command -v visudo >/dev/null 2>&1 || die "sudo is present, but visudo is unavailable."
  # A dedicated sudoers rule is sufficient; no broad supplementary groups are required.
  run_privileged install -d -m 0750 "$SUDOERS_DIR"
  sudoers_tmp="$(run_privileged mktemp "$SUDOERS_DIR/.ansible-bootstrap.XXXXXX")"
  trap 'if [[ -n "${sudoers_tmp:-}" ]]; then run_privileged rm -f -- "$sudoers_tmp"; fi' EXIT
  printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$username" | run_privileged tee "$sudoers_tmp" >/dev/null
  run_privileged chmod 0440 "$sudoers_tmp"
  if ! run_privileged visudo -cf "$sudoers_tmp" >/dev/null; then
    die "sudoers syntax validation failed; refusing to install the rule."
  fi
  run_privileged install -o root -g root -m 0440 "$sudoers_tmp" "$SUDOERS_DIR/ansible-$username"
  run_privileged rm -f "$sudoers_tmp"
  sudoers_tmp=""
fi

key_was_supplied=false
if [[ -n "$public_key" ]]; then
  key_was_supplied=true
  user_home="$(getent passwd "$username" | cut -d: -f6)"
  [[ -n "$user_home" && -d "$user_home" ]] || die "Cannot determine the home directory for $username."
  run_privileged install -d -m 0700 -o "$username" -g "$(id -gn "$username")" "$user_home/.ssh"
  authorized_keys="$user_home/.ssh/authorized_keys"
  run_privileged touch "$authorized_keys"
  run_privileged chmod 0600 "$authorized_keys"
  run_privileged chown "$username:$(id -gn "$username")" "$authorized_keys"
  if ! run_privileged grep -Fqx -- "$public_key" "$authorized_keys"; then
    printf '%s\n' "$public_key" | run_privileged tee -a "$authorized_keys" >/dev/null
  fi
  log "Installed SSH public key for $username."
fi
unset public_key

if command -v systemctl >/dev/null 2>&1; then
  run_privileged systemctl enable --now ssh 2>/dev/null || run_privileged systemctl enable --now sshd 2>/dev/null || die "Could not enable/start the SSH service."
elif command -v service >/dev/null 2>&1; then
  run_privileged service ssh start || die "Could not start the SSH service."
else
  die "Cannot manage the SSH service: neither systemctl nor service is available."
fi

log "Bootstrap completed successfully."
log "User: $username"
log "SSH service is enabled and running; Python 3 is installed."
if [[ "$configure_sudo" == true ]]; then
  log "Passwordless sudo is configured for this account."
else
  log "sudo is not installed; no sudoers rule was created. Manage this host using an appropriate root/escalation strategy in Ansible."
fi
if [[ "$key_was_supplied" != true ]]; then
  log "No SSH public key was supplied. Add one before relying on key-based SSH authentication."
fi
log "Test SSH from the Ansible control node: ssh $username@<host>"
if [[ "$configure_sudo" == true ]]; then
  log "Test privilege escalation: ssh $username@<host> 'sudo -n whoami' (expected: root)"
fi
