# Ansible Linux Bootstrap

Prepare a Debian-based Linux host for management with Ansible over SSH. The script installs its required packages, provisions an automation account, grants passwordless sudo, and enables the SSH service at boot.

## Supported systems

- Debian
- Ubuntu
- Raspberry Pi OS
- DietPi

The target needs APT package repositories and a service manager (systemd, or the SysV `update-rc.d`/service tools).

## Run

Pass the account details as key=value arguments:

```bash
sudo ./bootstrap-ansible-user.sh username=sysadmin password='change-this-password'
```

Optionally add an SSH public key:

```bash
sudo ./bootstrap-ansible-user.sh username=sysadmin password='change-this-password' ssh_public_key='ssh-ed25519 AAAA...'
```

Quote values that contain shell-special characters. A password passed as a command-line argument can appear in shell history and process inspection. Use a unique credential and remove it from shell history after use. The script sends the password to `chpasswd` over standard input rather than putting it in that program's arguments.

For a remote run, review the script and then:

```bash
curl -fsSL https://raw.githubusercontent.com/Michdo93/ansible-linux-bootstrap/main/bootstrap-ansible-user.sh | sudo bash -s -- username=sysadmin password='change-this-password'
```

## What the script configures

- Installs `sudo`, `openssh-server`, and `python3` with APT.
- Creates the account if missing; otherwise preserves its home directory, shell, and group memberships while setting the supplied password.
- Adds a validated `NOPASSWD: ALL` sudoers rule for Ansible privilege escalation.
- Adds an optional public key to `authorized_keys`.
- Enables and starts the SSH service so it starts automatically after reboot.

The account has full root access through sudo. Keep its credentials and SSH private key secure.

## Verify access

```bash
ssh sysadmin@HOSTNAME_OR_IP
ssh sysadmin@HOSTNAME_OR_IP 'sudo -n whoami'
ssh sysadmin@HOSTNAME_OR_IP 'python3 --version'
```

The sudo check should print `root`.

## Use with Ansible

Example inventory:

```ini
[linux]
host1 ansible_host=192.0.2.10

[linux:vars]
ansible_user=sysadmin
ansible_become=true
ansible_become_method=sudo
```

Test the connection and privilege escalation:

```bash
ansible linux -i inventory.ini -m ansible.builtin.ping
ansible linux -i inventory.ini -b -m ansible.builtin.command -a 'whoami'
```

Use Ansible Vault or another secrets manager for passwords. SSH public-key authentication is recommended for routine management. `sshpass`, if needed for SSH password authentication, belongs on the Ansible control node rather than the managed host.

## Security

- The automation account can run any command as root through sudo.
- Restrict SSH access to trusted management sources and protect private keys.
- Review the script before running it as root.
- Pin remote script URLs to a reviewed commit for repeatable deployments.

## License

Choose a license appropriate for your project before publishing.
