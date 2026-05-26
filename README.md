# antscihub-pi-service-manager

A service manager that monitors, updates, and maintains managed services on a Raspberry Pi fleet. Runs as a systemd service, pulls updates from git on every boot, and reports health status over encrypted MQTT.

## Scope

- Manage, update, and monitor systemd-backed services across a Raspberry Pi fleet.
- Auto-pull repositories and run service-specific `install.sh` scripts.
- Perform health checks, restart escalation, and encrypted MQTT reporting to the orchestrator.
- Declarative service registration via `antscihub.manifest` and `config/modules.conf`.

## Project status
Stable for implementation. Edits not needed or compartmentalized elsewhere.


- **Status:** Active — core features implemented and in use.
- **Stability:** Stable — install/update and monitoring flows validated on Raspberry Pi devices.

## Install
Initial antscihub-pi-setup must be installed. pi-setup SHOULD do the commands below, but if it does not for some reason, the legacy implementation is:

From any Pi (via fleet shell or SSH):

```bash
sudo git clone https://github.com/soulsynapse/antscihub-pi-service-manager.git ~/Desktop/2-SERVICE-MANAGER
cd ~/Desktop/2-SERVICE-MANAGER && sudo bash install.sh
```

During install, module repos listed in `config/modules.conf` are also cloned or updated.

**Prerequisites:** Fleet shell must be installed first (`setup_pi.sh`), which provides the MQTT client, encryption, and `fleet-publish` command.

## Update

Updates are startup-triggered (one-shot), not continuous polling. On each
`antscihub-service-manager` start (boot or `systemctl restart`), the service
manager runs one boot update pass, then enters steady-state monitoring.

During the startup update pass, the service manager:

- Pulls its own repo — if changed, re-runs `install.sh` and restarts itself
- Pulls each managed service repo — if changed, runs its `install.sh` and restarts the service

Important behavior:

- A new commit pushed to GitHub is applied the next time the service starts
- The 30-second health loop does **not** perform git pulls
- To apply a pushed change immediately, restart the service

To force an update manually:

```bash
cd ~/Desktop/2-SERVICE-MANAGER && sudo git checkout -- . && sudo git pull --ff-only && sudo bash install.sh
```

Or via fleet orchestrator to all Pis:

```bash
SM=$(find /home/*/Desktop/2-SERVICE-MANAGER -maxdepth 1 -name ".git" -type d 2>/dev/null | head -1 | xargs dirname) && cd "$SM" && sudo git checkout -- . && sudo git pull --ff-only && sudo bash install.sh
```

## How It Works

- **At service start (boot/restart):** runs one update/install pass (self repo + managed repos), then continues
- **Every 30 seconds:** health monitoring only (service checks/restarts + status report), no git pull/update pass
- **Restart escalation:** 3 consecutive failures triggers restart, gives up after 5 attempts
- **Reports to:** `fleet/response/{device_id}` (encrypted) using `fleet.service-manager.v1` schema

## Adding a Managed Service

### 1. Create your repo

Your service repo needs two files at minimum:

**`antscihub.manifest`** — tells the service manager about your service:

```ini# Required
SERVICE_NAME=my-service.service
GIT_REMOTE=https://github.com/your-org/your-repo.git
INSTALL_CMD=bash install.sh

# Optional
STARTUP_GRACE=10
GIT_BRANCH=main
NO_AUTO_RESTART=false
```

| Field | Required | Description |
|-------|----------|-------------|
| `SERVICE_NAME` | Yes | The systemd service name (e.g. `my-service.service`) |
| `GIT_REMOTE` | Yes | Git URL for the repo |
| `INSTALL_CMD` | Yes | Command to install/configure the service. Runs from the repo directory as root. Use `bash install.sh`, NOT `sudo bash install.sh` (already running as root) |
| `STARTUP_GRACE` | No | Seconds to wait after restart before checking health (default: 10) |
| `GIT_BRANCH` | No | Git branch to track (default: main) |
| `NO_AUTO_RESTART` | No | Set to `true` to disable automatic restart on failure |

**`install.sh`** — installs your service:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fix permissions FIRST
chmod +x "${SCRIPT_DIR}"/*.sh

# Generate systemd unit with absolute path
cat > /etc/systemd/system/my-service.service << EOF
[Unit]
Description=My Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SCRIPT_DIR}/my-service.sh
WorkingDirectory=${SCRIPT_DIR}
Restart=always
RestartSec=10
User=root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable my-service.service

echo "[my-service] install complete"
```

### 2. Register in modules.conf

Add your repo to `config/modules.conf` in this repo:

```
https://github.com/your-org/your-repo.git|~/Desktop/3-SYSTEM/your-service
```

Format: `REPO_URL|TARGET_PATH` — one per line. Lines starting with `#` are ignored.

### 3. Push and deploy

Commit and push both repos. On next service manager restart/reboot, it will:

- Clone your repo to the target path
- Run your `install.sh`
- Start monitoring the systemd service
- Report health status over MQTT

## Important notes for install.sh

- Always use `chmod +x` on your scripts first — git may not preserve executable permissions
- Generate the `.service` file dynamically using `${SCRIPT_DIR}` for absolute paths — don't hardcode paths or use `~`
- Don't use `sudo` — the service manager already runs as root
- Use `systemctl enable` but NOT `systemctl start` — the service manager handles starting and restarting
- Use `set -euo pipefail` — so failures are caught and reported

## MQTT Reporting

Your service can publish events over MQTT using `fleet-publish`:

```bash
fleet-publish \
    --topic "fleet/response/${DEVICE_ID}" \
    --json '{"schema":"fleet.service-manager.v1","event":"my_event","service":"my-service","device_id":"'${DEVICE_ID}'","timestamp":'$(date +%s)',"message":"Something happened"}'
```

All messages are encrypted automatically. The orchestrator GUI classifies events by:

- **Explicit severity field** — set `"severity":"WARNING"` to override auto-classification
- **success field** — `true` = INFO, `false` = ERROR
- **Event name patterns** — words like `fail`, `error`, `restart` auto-classify as WARNING/ERROR

Available severity levels: `ROUTINE`, `INFO`, `ATTENTION`, `WARNING`, `ERROR`

## File Structure

```
config/
  service-manager.conf    # Main configuration
  modules.conf            # List of managed service repos
services/
  service-manager.sh      # The service manager script
  antscihub-service-manager.service  # systemd unit file
install.sh                # Installer
README.md                 # This file
```

## Configuration

`config/service-manager.conf`:
| Setting | Default | Description |
|---------|---------|-------------|
| `SERVICES_DIR` | Set during install | Where to scan for managed services |
| `CHECK_INTERVAL` | 30 | Seconds between health checks |
| `RESTART_THRESHOLD` | 3 | Consecutive failures before restart attempt |
| `MAX_RESTART_ATTEMPTS` | 5 | Restart attempts before giving up |
| `PULL_ON_BOOT` | true | Run the one-shot startup pull/install pass when the service starts |
| `SELF_REPO_DIR` | Set during install | Git checkout path used for startup self-updates |

## Troubleshooting

```bash# Service manager status and logs
sudo systemctl status antscihub-service-manager --no-pager
sudo journalctl -u antscihub-service-manager --no-pager -n 50

# Check what services are discovered
find ~/Desktop -name "antscihub.manifest" 2>/dev/null

# Force re-pull and reinstall everything
cd ~/Desktop/2-SERVICE-MANAGER && sudo git checkout -- . && sudo git pull --ff-only && sudo bash install.sh

# Restart to trigger boot update
sudo systemctl restart antscihub-service-manager
```

