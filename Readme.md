# Ansible repo

Collection of ansible playbooks and tasks i use. Use at you own risk.

## 🚨 Critical Warnings
**Firewall & Security**
By default, these playbooks will **enable UFW and Fail2Ban**.
* **Connection Risk:** Ensure you have configured your own SSH allow rules in the firewall settings before running these playbooks, or you may lock yourself out of your server.
* **Custom Rules:** You must add your own firewall rules on top of the defaults provided here.


## Commands
```bash
# Run normally
ansible-playbook -i your_inventory_file playbook_name # add -Kk to use password auth

# This runs ONLY tasks tagged with 'update'
ansible-playbook -i your_inventory_file site.yml --tags "update"

# Cleanup ansible generated snapshots
ansible-playbook -i your_inventory_file site.yml --tags "manual_cleanup"
```