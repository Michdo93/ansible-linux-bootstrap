# Ansible Linux Bootstrap

A small interactive bootstrap script that prepares a Debian-based Linux host for management with Ansible.

It is designed for Debian, Ubuntu, Raspberry Pi OS, and DietPi. The script detects the installed distribution, installs the required packages, creates or updates a dedicated automation account, configures passwordless `sudo` when `sudo` is installed, and enables SSH.

## What it does

- Detects the operating system using `/etc/os-release`.
- Prompts interactively for the account username and password. Password input is hidden and confirmed.
- Checks whether `sudo` is available. If it is, privileged operations are run through `sudo` and a passwordless sudo rule is configured for the automation account. If it is absent, privileged operations are run directly, so the script must be run as `root`. The script does not install `sudo`.
- Installs `openssh-server` and `python3` with APT.
- Creates the account if it does not exist. If it already exists, its home directory, shell, and group memberships are preserved.
- Sets the account password.
- Optionally adds a dedicated `/etc/sudoers.d/` rule granting the account passwordless sudo, after validating the rule with `visudo`.
- Enables and starts the SSH service.
- Optionally accepts one SSH public key and installs it in the account's `authorized_keys` file.

The account has broad administrative privileges through `sudo`. Protect its SSH private key and use this level of access only for trusted automation accounts.

## Supported systems

- Debian
- Ubuntu
- Raspberry Pi OS
- DietPi

The script expects a Debian-based system using `apt-get`, a working package repository, and an interactive terminal. If `sudo` is installed, the script uses it for privileged commands; otherwise, run the script as `root`. It does not install Ansible on the managed host, configure DNS or static IP addresses, change the SSH server's password-authentication policy, or install `sshpass` on the managed host.

## Run from GitHub without keeping a local script file

Review the script before running it. Replace `OWNER` with the GitHub account or organization that owns this repository:

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/ansible-linux-bootstrap/main/bootstrap-ansible-user.sh | sudo bash
```

The script is streamed to Bash and is not saved as a script file on the managed host. It reads interactive answers directly from `/dev/tty`, so prompts still work when the script itself comes through a pipe.

For production use, pin the URL to a reviewed commit rather than following a moving branch. Piping a remote script directly to a root shell is convenient but means that code served by that URL runs with full administrative privileges.

## Run a local copy

```bash
chmod +x bootstrap-ansible-user.sh
sudo ./bootstrap-ansible-user.sh
```

The script asks for:

1. The dedicated Linux account username (for example, `sysadmin`).
2. The account password, entered twice without echoing it to the terminal.
3. Whether to configure passwordless `sudo` (default: yes). Answer `n` to skip installing and configuring `sudo`.
4. An optional SSH public key. Press Enter to skip this step.

The password is not passed as a command-line argument and is not written to the script or shell history. As with any account password, it is processed in memory and passed to the system password utility to set the account password.

## Test the host from the Ansible control node

First, verify SSH access:

```bash
ssh sysadmin@HOSTNAME_OR_IP
```

If you enabled sudo during setup, verify that it works without prompting for a password:

```bash
ssh sysadmin@HOSTNAME_OR_IP 'sudo -n whoami'
```

Expected output:

```text
root
```

If the target does not have `sudo` (for example, a Proxmox VE host managed through its root account), this check does not apply. Configure Ansible to connect as an appropriately privileged user and avoid `become_method=sudo` for that host, or use an escalation method supported by the host.

Check Python as well:

```bash
ssh sysadmin@HOSTNAME_OR_IP 'python3 --version'
```

## Use with Ansible

Example inventory:

```ini
[linux]
host1 ansible_host=192.0.2.10
host2 ansible_host=192.0.2.11

[linux:vars]
ansible_user=sysadmin
ansible_become=true
ansible_become_method=sudo  # only for hosts where sudo is installed and configured
```

Test connectivity and privilege escalation:

```bash
ansible linux -i inventory.ini -m ansible.builtin.ping
ansible linux -i inventory.ini -b -m ansible.builtin.command -a 'whoami'
```

The second command should report `root` for each host if sudo was configured and enabled in the inventory.

## Notes on SSH keys and `sshpass`

SSH public-key authentication is recommended for routine Ansible use. You can paste a single public key during setup; the corresponding private key must remain on the Ansible control node. If you skip the key prompt, the script does not change the SSH server's authentication policy. Whether password-based SSH login is available depends on the host's existing SSH configuration.

`sshpass` is generally needed only on the Ansible control node if you deliberately use SSH password authentication. It is not required on managed hosts when using SSH keys.

## Security considerations

- If enabled, the configured `NOPASSWD: ALL` rule allows the account to run any command as root. This is convenient for general system administration and package upgrades, but it is not least-privilege access. If `sudo` is absent, the script does not install it or write a sudoers rule; it executes privileged commands directly and therefore requires root.
- Keep the account's SSH private key secure and restrict access to the Ansible control node.
- Review the script before running it as root, especially when downloading it from a public repository.
- For more restrictive environments, replace `NOPASSWD: ALL` with a carefully designed privilege policy appropriate to the actual playbooks.
- This script is intended for initial setup, not as a complete security-hardening solution.

## License

Choose a license appropriate for your project before publishing (for example, MIT).
