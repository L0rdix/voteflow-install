# VoteFlow — Proxmox LXC Installer

One-command installer for [VoteFlow](https://gitlab.com/your-gitlab-group/26ss-se-pr-qse-09) on Proxmox VE.

Paste this into your Proxmox host shell:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/L0rdix/voteflow-install/main/install.sh)"
```

## What it does
1. Downloads an Ubuntu 22.04 LXC template (if not already cached)
2. Creates a privileged LXC container with Docker inside
3. Pulls the latest VoteFlow image from Docker Hub
4. Writes the configuration and starts the container (auto-restarts on boot)

## Requirements
- Proxmox VE 7 or 8
- Internet access on the Proxmox host
- A Gmail account with an App Password for email notifications

## What you'll be asked
- Gmail address and app password (for sending vote notification emails)
- Container settings (ID, hostname, storage, memory, CPU, disk) — all have sensible defaults, just press Enter

## After installation
The app will be available at http://<container-ip>:8080.
To find the container IP: pct exec <CTID> -- ip -4 addr show eth0
To edit the configuration: pct exec <CTID> -- nano /opt/voteflow/.env
