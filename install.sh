#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# antscihub-pi-service-manager installer
# Installs the service manager and bootstraps configured module repos.
# Safe to re-run.
# Usage: sudo bash install.sh
# =============================================================================

INSTALL_DIR="/opt/antscihub-pi-service-manager"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_FILE="${SCRIPT_DIR}/config/modules.conf"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[install]${NC} $*"; }
warn() { echo -e "${YELLOW}[install]${NC} $*"; }
err()  { echo -e "${RED}[install]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    err "Must run as root: sudo bash install.sh"
    exit 1
fi

# Supports both manual sudo installs and unattended self-reinstall runs.
# In self-reinstall, SUDO_USER is typically unset, so resolve a real user.
REAL_USER="${SUDO_USER:-}"
if [[ -z "${REAL_USER}" ]]; then
    REAL_USER=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}')
fi
if [[ -z "${REAL_USER}" ]]; then
    for d in /home/*/Desktop/1-MQTT /home/*/1-MQTT; do
        if [[ -d "$d" ]]; then
            REAL_USER=$(echo "$d" | cut -d/ -f3)
            break
        fi
    done
fi
REAL_USER="${REAL_USER:-pi}"
REAL_GROUP=$(id -gn "${REAL_USER}" 2>/dev/null || echo "${REAL_USER}")

# FIX #11: resolve home via getent instead of eval
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
if [[ -z "$REAL_HOME" ]]; then
    # Fallback if getent fails
    REAL_HOME="/home/${REAL_USER}"
fi
DESKTOP_DIR="${REAL_HOME}/Desktop"
MANAGER_REPO_DIR="${DESKTOP_DIR}/2-SERVICE-MANAGER"

# Run git commands as the real user, not root
git_as_user() {
    sudo -u "${REAL_USER}" git "$@"
}

ensure_user_dir() {
    local dir="$1"
    mkdir -p "$dir"
    if id -u "${REAL_USER}" >/dev/null 2>&1; then
        chown "${REAL_USER}:${REAL_GROUP}" "$dir" 2>/dev/null || true
    fi
}

git_repo_branch() {
    local dir="${1%/}"
    local fallback="${2:-main}"
    local branch

    branch=$(git_as_user -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
        branch="$fallback"
    fi
    echo "$branch"
}

git_common_dir_for_repo() {
    local dir="${1%/}"
    local git_dir

    git_dir=$(git_as_user -C "$dir" rev-parse --git-common-dir 2>/dev/null || true)
    if [[ -z "$git_dir" ]]; then
        git_dir="${dir}/.git"
    elif [[ "$git_dir" != /* ]]; then
        git_dir="${dir}/${git_dir}"
    fi
    echo "$git_dir"
}

remove_transient_git_refs() {
    local dir="${1%/}"
    local git_dir
    git_dir=$(git_common_dir_for_repo "$dir")

    [[ -d "$git_dir" ]] || return 0

    local ref_file
    for ref_file in ORIG_HEAD FETCH_HEAD MERGE_HEAD REBASE_HEAD CHERRY_PICK_HEAD; do
        if [[ -e "${git_dir}/${ref_file}" ]]; then
            warn "${dir}: removing transient git ref ${ref_file}"
            rm -f "${git_dir}/${ref_file}" 2>/dev/null || true
        fi
    done

    find "$git_dir" -type f -name "*.lock" -mmin +10 -print -delete 2>/dev/null \
        | while IFS= read -r lock_file; do
            warn "${dir}: removed stale git lock ${lock_file}"
        done
}

fetch_reset_repo() {
    local dir="${1%/}"
    local remote="$2"
    local branch="$3"

    [[ -n "$branch" ]] || branch="main"

    if [[ -n "$remote" ]]; then
        if git_as_user -C "$dir" remote get-url origin >/dev/null 2>&1; then
            git_as_user -C "$dir" remote set-url origin "$remote" 2>/dev/null || true
        else
            git_as_user -C "$dir" remote add origin "$remote" 2>/dev/null || true
        fi
    fi

    remove_transient_git_refs "$dir"

    if ! git_as_user -C "$dir" fetch --prune origin "+refs/heads/${branch}:refs/remotes/origin/${branch}"; then
        return 1
    fi
    if ! git_as_user -C "$dir" reset --hard "origin/${branch}"; then
        return 1
    fi
    git_as_user -C "$dir" clean -fd || true
    return 0
}

REPO_REPAIRED_BY_RECLONE=false

reclone_repo() {
    local dir="${1%/}"
    local remote="$2"
    local branch="$3"
    local reason="${4:-git repair failed}"

    if [[ -z "$remote" ]]; then
        warn "${dir}: cannot reclone; no remote URL available"
        return 1
    fi

    local parent base abs_dir tmp_dir
    parent=$(cd "$(dirname "$dir")" 2>/dev/null && pwd) || return 1
    base=$(basename "$dir")
    abs_dir="${parent}/${base}"

    tmp_dir=$(sudo -u "$REAL_USER" mktemp -d "${parent}/.${base}.reclone.XXXXXX") || return 1
    rmdir "$tmp_dir" 2>/dev/null || true

    warn "${dir}: recloning from ${remote} (${reason})"
    if [[ -n "$branch" ]]; then
        if ! git_as_user clone --branch "$branch" "$remote" "$tmp_dir"; then
            rm -rf "$tmp_dir" 2>/dev/null || true
            tmp_dir=$(sudo -u "$REAL_USER" mktemp -d "${parent}/.${base}.reclone.XXXXXX") || return 1
            rmdir "$tmp_dir" 2>/dev/null || true
            if ! git_as_user clone "$remote" "$tmp_dir"; then
                rm -rf "$tmp_dir" 2>/dev/null || true
                return 1
            fi
        fi
    elif ! git_as_user clone "$remote" "$tmp_dir"; then
        rm -rf "$tmp_dir" 2>/dev/null || true
        return 1
    fi

    if [[ -e "$abs_dir" ]]; then
        warn "${dir}: removing broken checkout before reclone"
        if ! rm -rf "$abs_dir"; then
            warn "${dir}: failed to remove broken checkout"
            rm -rf "$tmp_dir" 2>/dev/null || true
            return 1
        fi
    fi
    if ! mv "$tmp_dir" "$abs_dir"; then
        warn "${dir}: failed to install repaired checkout"
        rm -rf "$tmp_dir" 2>/dev/null || true
        return 1
    fi

    chown -R "${REAL_USER}:${REAL_GROUP}" "$abs_dir" 2>/dev/null || true
    warn "${dir}: replaced broken checkout with clean clone"
    REPO_REPAIRED_BY_RECLONE=true
    return 0
}

update_repo() {
    local dir="${1%/}"
    local remote="$2"
    local branch="${3:-}"

    REPO_REPAIRED_BY_RECLONE=false
    [[ -n "$branch" ]] || branch=$(git_repo_branch "$dir" "main")

    git_as_user -C "$dir" checkout -- . 2>/dev/null || true
    if git_as_user -C "$dir" pull --ff-only; then
        return 0
    fi

    warn "Pull failed for ${dir}; trying fetch/reset repair"
    if fetch_reset_repo "$dir" "$remote" "$branch"; then
        return 0
    fi

    warn "Fetch/reset repair failed for ${dir}; trying reclone"
    reclone_repo "$dir" "$remote" "$branch" "pull failed and refs could not be repaired"
}

MQTT_DIR="${DESKTOP_DIR}/1-MQTT"
VENV_PYTHON="${MQTT_DIR}/venv/bin/python3"

log "User=${REAL_USER} Home=${REAL_HOME} Desktop=${DESKTOP_DIR}"

# ─── Helpers ──────────────────────────────────────────────────────────────────

expand_module_path() {
    local raw_path="$1"
    raw_path="${raw_path//$'\r'/}"
    raw_path="${raw_path#\"}"
    raw_path="${raw_path%\"}"
    raw_path="${raw_path#\'}"
    raw_path="${raw_path%\'}"

    case "$raw_path" in
        '~/'*)
            echo "${REAL_HOME}/${raw_path:2}"
            ;;
        "\$HOME/"*)
            echo "${REAL_HOME}/${raw_path#\$HOME/}"
            ;;
        "\${HOME}/"*)
            echo "${REAL_HOME}/${raw_path#\${HOME}/}"
            ;;
        *)
            echo "$raw_path"
            ;;
    esac
}

run_module_install() {
    local module_dir="$1"

    if [[ ! -f "${module_dir}/antscihub.manifest" ]]; then
        return
    fi

    local install_cmd=""
    while IFS='=' read -r mkey mval; do
        [[ "$mkey" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$mkey" ]] && continue
        mkey=$(echo "$mkey" | xargs)
        mval=$(echo "$mval" | xargs)
        if [[ "$mkey" == "INSTALL_CMD" ]]; then
            install_cmd="$mval"
        fi
    done < "${module_dir}/antscihub.manifest"

    if [[ -n "$install_cmd" ]]; then
        log "Running install for $(basename "${module_dir}"): ${install_cmd}"
        find "${module_dir}" -name "*.sh" -exec chmod +x {} + 2>/dev/null || true
        if ! (cd "${module_dir}" && bash -c "$install_cmd"); then
            warn "Install failed for $(basename "${module_dir}")"
        fi
    fi
}

install_modules() {
    if [[ ! -f "${MODULES_FILE}" ]]; then
        warn "No modules file at ${MODULES_FILE}; skipping module bootstrap"
        return
    fi

    log "Bootstrapping modules from ${MODULES_FILE}..."

    while IFS='|' read -r repo_url target_path; do
        [[ -z "${repo_url// /}" ]] && continue
        [[ "${repo_url}" =~ ^[[:space:]]*# ]] && continue

        repo_url="$(echo "${repo_url}" | xargs)"
        target_path="$(echo "${target_path}" | xargs)"

        if [[ -z "$repo_url" || -z "$target_path" ]]; then
            warn "Invalid module line, expected REPO_URL|TARGET_PATH"
            continue
        fi

        local resolved_target
        resolved_target="$(expand_module_path "$target_path")"
                if [[ "$resolved_target" == '~/'* ]]; then
            resolved_target="${REAL_HOME}/${resolved_target:2}"
        fi
        local module_name
        module_name="$(basename "${resolved_target%/}")"

        log "Module target resolved: ${target_path} -> ${resolved_target} (${module_name})"

        local resolved_parent
        resolved_parent="$(dirname "${resolved_target}")"
        ensure_user_dir "$resolved_parent"

        if [[ -d "${resolved_target}/.git" ]]; then
            log "Updating module ${module_name}: ${repo_url} -> ${resolved_target}"
            local branch="main"
            if [[ -f "${resolved_target}/antscihub.manifest" ]]; then
                while IFS="=" read -r mkey mval; do
                    [[ "$mkey" == "GIT_BRANCH" ]] && branch="$(echo "$mval" | xargs)"
                done < "${resolved_target}/antscihub.manifest"
            fi
            local old_head new_head
            old_head=$(git_as_user -C "${resolved_target}" rev-parse HEAD 2>/dev/null || echo "unknown")
            if ! update_repo "${resolved_target}" "${repo_url}" "$branch"; then
                warn "Failed to update or repair ${resolved_target}; continuing"
            elif [[ "$REPO_REPAIRED_BY_RECLONE" == "true" ]]; then
                log "Module ${module_name} was recloned/repaired; running install"
                run_module_install "${resolved_target}"
            else
                new_head=$(git_as_user -C "${resolved_target}" rev-parse HEAD 2>/dev/null || echo "unknown")
                if [[ "$old_head" != "$new_head" ]]; then
                    log "Module ${module_name} updated ${old_head:0:8} -> ${new_head:0:8}; running install"
                else
                    log "Module ${module_name} already up to date (${old_head:0:8}); running install to ensure local tools are current"
                fi
                run_module_install "${resolved_target}"
            fi
        elif [[ -e "${resolved_target}" ]]; then
            if [[ -d "${resolved_target}" ]] && [[ -z "$(find "${resolved_target}" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
                log "Cloning module into existing empty dir: ${repo_url} -> ${resolved_target}"
                rmdir "${resolved_target}" 2>/dev/null || true
                if ! git_as_user clone "${repo_url}" "${resolved_target}"; then
                    warn "Failed to clone ${repo_url} into ${resolved_target}; continuing"
                    continue
                fi
                run_module_install "${resolved_target}"
            else
                warn "Target exists and is not a git repo, skipping: ${resolved_target}"
                warn "If this path should be managed, remove or rename it, then re-run install.sh"
                continue
            fi
        else
            log "Cloning module: ${repo_url} -> ${resolved_target}"
            if ! git_as_user clone "${repo_url}" "${resolved_target}"; then
                warn "Failed to clone ${repo_url} into ${resolved_target}; continuing"
                continue
            fi
            run_module_install "${resolved_target}"
        fi

        if id -u "${REAL_USER}" >/dev/null 2>&1; then
            chown -R "${REAL_USER}:${REAL_GROUP}" "${resolved_target}" 2>/dev/null || true
        fi
    done < "${MODULES_FILE}"
}

# ─── Preflight ────────────────────────────────────────────────────────────────

if [[ ! -d "${MQTT_DIR}" ]]; then
    err "MQTT directory not found at ${MQTT_DIR}"
    err "Is fleet-shell installed? Run the fleet-shell installer first."
    exit 1
fi

if [[ ! -f "${VENV_PYTHON}" ]]; then
    err "Python venv not found at ${VENV_PYTHON}"
    err "Is fleet-shell installed correctly?"
    exit 1
fi

if ! "${VENV_PYTHON}" -c "import paho.mqtt.client; from cryptography.fernet import Fernet" 2>/dev/null; then
    err "MQTT venv missing required packages"
    err "Re-run fleet-shell installer or: ${MQTT_DIR}/venv/bin/pip install paho-mqtt cryptography python-dotenv"
    exit 1
fi

if ! command -v git &>/dev/null; then
    log "Installing git..."
    apt-get update -qq && apt-get install -y -qq git > /dev/null 2>&1
fi

# Bootstrap modules before setting up service
install_modules

# ─── Stop old service ─────────────────────────────────────────────────────────

# Stop old meta service if it exists
systemctl stop antscihub-meta 2>/dev/null || true
systemctl disable antscihub-meta 2>/dev/null || true
rm -f /etc/systemd/system/antscihub-meta.service

# Stop service-manager if already running.
# During self-reinstall (triggered from within service-manager itself),
# skipping this avoids killing the in-progress updater process.
if [[ "${SELF_REINSTALL:-false}" == "true" ]]; then
    log "SELF_REINSTALL=true: skipping explicit stop of antscihub-service-manager"
else
    systemctl stop antscihub-service-manager 2>/dev/null || true
fi

# ─── Copy files ───────────────────────────────────────────────────────────────

log "Installing to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}/config"
mkdir -p "${INSTALL_DIR}/services"
mkdir -p "${MANAGER_REPO_DIR}"

# Copy everything — config values are set by sed below, so a fresh copy is fine
rsync -a --exclude='.git' --exclude='.gitignore' "${SCRIPT_DIR}/" "${INSTALL_DIR}/"

# Remove old meta files if present
rm -f "${INSTALL_DIR}/services/meta-service.sh"
rm -f "${INSTALL_DIR}/services/antscihub-meta.service"
rm -f "${INSTALL_DIR}/config/meta.conf"

chmod +x "${INSTALL_DIR}/services/service-manager.sh"

# Migrate meta.conf → service-manager.conf if needed
if [[ -f "${INSTALL_DIR}/config/meta.conf" && ! -f "${INSTALL_DIR}/config/service-manager.conf" ]]; then
    log "Migrating meta.conf → service-manager.conf"
    mv "${INSTALL_DIR}/config/meta.conf" "${INSTALL_DIR}/config/service-manager.conf"
fi

# Set SERVICES_DIR in config if blank
if grep -q '^SERVICES_DIR=""' "${INSTALL_DIR}/config/service-manager.conf" 2>/dev/null; then
    sed -i "s|^SERVICES_DIR=\"\"|SERVICES_DIR=\"${DESKTOP_DIR}\"|" "${INSTALL_DIR}/config/service-manager.conf"
fi

# Set SELF_REPO_DIR in config if blank
if grep -q '^SELF_REPO_DIR=""' "${INSTALL_DIR}/config/service-manager.conf" 2>/dev/null; then
    SELF_REPO_DIR_DEFAULT="${INSTALL_DIR}"
    if [[ -d "${SCRIPT_DIR}/.git" ]]; then
        SELF_REPO_DIR_DEFAULT="${SCRIPT_DIR}"
    elif [[ -d "${MANAGER_REPO_DIR}/.git" ]]; then
        SELF_REPO_DIR_DEFAULT="${MANAGER_REPO_DIR}"
    fi
    log "Setting SELF_REPO_DIR=${SELF_REPO_DIR_DEFAULT}"
    sed -i "s|^SELF_REPO_DIR=\"\"|SELF_REPO_DIR=\"${SELF_REPO_DIR_DEFAULT}\"|" "${INSTALL_DIR}/config/service-manager.conf"
fi

# ─── Disable Wi-Fi power management ──────────────────────────────────────────

log "Disabling Wi-Fi power management..."

mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/99-antscihub-wifi-powersave.conf <<'EOF'
[connection]
wifi.powersave = 2
EOF

# FIX #14: Use iw if available, fall back to iwconfig, handle both in udev rule
if command -v iw &>/dev/null; then
    IW_CMD="/usr/sbin/iw dev %k set power_save off"
elif command -v iwconfig &>/dev/null; then
    IW_CMD="/usr/sbin/iwconfig %k power off"
else
    IW_CMD=""
    warn "Neither iw nor iwconfig found; Wi-Fi power-save udev rule skipped"
fi

if [[ -n "$IW_CMD" ]]; then
    cat > /etc/udev/rules.d/70-antscihub-wifi-powersave.rules <<EOF
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*", RUN+="${IW_CMD}"
EOF
fi

# Apply immediately to wlan0 if it exists
if ip link show wlan0 &>/dev/null; then
    if command -v iw &>/dev/null; then
        iw dev wlan0 set power_save off 2>/dev/null || true
    elif command -v iwconfig &>/dev/null; then
        iwconfig wlan0 power off 2>/dev/null || true
    fi
fi

# ─── Install systemd unit ────────────────────────────────────────────────────

log "Installing systemd service..."

cp "${INSTALL_DIR}/services/antscihub-service-manager.service" /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now antscihub-service-manager.service

sleep 3
if systemctl is-active --quiet antscihub-service-manager; then
    log "  ✓ antscihub-service-manager running"
else
    err "  ✗ antscihub-service-manager failed to start"
    journalctl -u antscihub-service-manager --no-pager -n 20 || true
fi

# ─── Report install ──────────────────────────────────────────────────────────

"${VENV_PYTHON}" -c "
import sys, time
sys.path.insert(0, '${MQTT_DIR}')
from mqtt_client import fleet, DEVICE_ID
fleet.loop_start()
if fleet.wait_until_connected(timeout=10):
    fleet.publish('fleet/response/' + DEVICE_ID, {
        'schema': 'fleet.service-manager.v1',
        'event': 'service_manager_installed',
        'device_id': DEVICE_ID,
        'timestamp': time.time(),
        'version': '$(git_as_user -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)',
        'install_dir': '${INSTALL_DIR}',
    }, encrypt=True)
    time.sleep(1)
fleet.loop_stop()
" 2>/dev/null || warn "Install report failed (non-critical)"

# ─── Done ─────────────────────────────────────────────────────────────────────

log "============================================"
log " antscihub-pi-service-manager installed!"
log ""
log " Config:  ${INSTALL_DIR}/config/service-manager.conf"
log " Logs:    journalctl -u antscihub-service-manager -f"
log " Status:  systemctl status antscihub-service-manager"
log ""
log " To add a managed service, place a folder"
log " in ${DESKTOP_DIR}/ with an"
log " antscihub.manifest file. See README."
log "============================================"
