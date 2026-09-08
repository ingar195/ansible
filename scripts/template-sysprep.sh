#!/bin/bash
# Run this ON the template VM itself, right before shutting it down and
# re-flagging it as a Proxmox template. Cleans up everything that must NOT
# be shared identically across every future clone.
set -euo pipefail

echo "=== Updating packages ==="
sudo apt update
sudo apt full-upgrade -y
sudo apt autoremove -y
sudo apt clean

echo "=== Cleaning cloud-init state (so it re-runs fresh on every clone) ==="
sudo cloud-init clean --logs

echo "=== Resetting machine-id (so every clone gets its own) ==="
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo ln -s /etc/machine-id /var/lib/dbus/machine-id

echo "=== Removing SSH host keys (regenerated fresh on first boot of each clone) ==="
sudo rm -f /etc/ssh/ssh_host_*

echo "=== Clearing shell history and logs ==="
rm -f "$HOME/.bash_history"
sudo rm -f /root/.bash_history
sudo find /home -maxdepth 1 -name .bash_history -delete
sudo truncate -s 0 /var/log/wtmp /var/log/btmp /var/log/lastlog 2>/dev/null || true
sudo journalctl --rotate
sudo journalctl --vacuum-time=1s

echo "=== Done. shutting down in 10 seconds, then convert this VM to a template in Proxmox. ==="
sleep 10
sudo shutdown -h now