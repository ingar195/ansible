# Ansible repo

This is a collection of ansible playbooks and tasks i use. Use at you own risk.
All taks is designed to be runned at a schedule

## 🚨 Critical Warnings
**Firewall & Security**
By default, these playbooks will **enable UFW and Fail2Ban**.
* **Connection Risk:** Ensure you have configured your own SSH allow rules in the firewall settings before running these playbooks, or you may lock yourself out of your server.
* **Custom Rules:** You must layer your own firewall rules on top of the defaults provided here.

# Commands 
`ansible-playbook -i your_inventory_file playbook_name # add -Kk to use password auth` 

# Todo:
* Some taks shows changes done when they should not