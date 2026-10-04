# Ansible deployment

Deploys the stack to any self-hosted Linux machine (this one or another box on the LAN): installs Podman,
loads `tun`, sets the SELinux boolean, enables linger, writes `.env` and credentials, starts the stack,
makes it come back after reboot and checks the public IP through the balancer.

The target needs the PIA client installed (`/opt/piavpn`); `servers.txt` and the CA certificate come from it.

```sh
sudo dnf install ansible        # includes ansible.posix and community.general
cd ansible
cp group_vars/vpn/vault.yml.example group_vars/vpn/vault.yml
ansible-vault encrypt group_vars/vpn/vault.yml   # then: ansible-vault edit ...
ansible-playbook site.yml -K --ask-vault-pass    # -K: sudo password for host preparation
```

Settings (regions, ports, `bind`) are in `group_vars/vpn/vars.yml`; hosts are in `inventory.yml`.
The stack is deployed to `~/.local/share/vpn_balancer`. If it is already running from the repo directory,
the playbook stops with a message - run `make down` there first.

Re-running is safe: nothing changes unless a file or setting changed, and then the stack is restarted.
