#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# antscihub-pi-service-manager  —  main daemon script
# ---------------------------------------------------------------------------
set -uo pipefail
# NOTE: intentionally no -e; this is a long-running daemon that must not exit
# on transient failures.  Every command that can fail is guarded explicitly.

CONF="/opt/antscihub-pi-service-manager/config/service-manager.conf"
LOG_TAG="antscihub-service-manager"

if [[ ! -f "$CONF" ]]; then
    logger -t "$LOG_TAG" "FATAL: config not found at ${CONF}"
    exit 1
fi
source "$CONF"

DEVICE_ID="${DEVICE_ID:-$(hostname)}"

# Resolve SERVICES_DIR dynamically if not set in config
if [[ -z "${SERVICES_DIR:-}" ]]; then
    # FIX #10/#11: use getent to resolve home safely, no eval
    REAL_USER=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}')
    REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
    SERVICES_DIR="${REAL_HOME}/Desktop"
    logger -t "$LOG_TAG" "SERVICES_DIR not set, resolved to ${SERVICES_DIR}"
fi

# Resolve SELF_REPO_DIR dynamically if not set in config
if [[ -z "${SELF_REPO_DIR:-}" ]]; then
    SELF_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    logger -t "$LOG_TAG" "SELF_REPO_DIR not set, resolved to ${SELF_REPO_DIR}"
fi
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
# NOTE: CHECK_INTERVAL controls health/status cadence only.
#       Repo pull/install behavior is handled by boot_update() at service start.
RESTART_THRESHOLD="${RESTART_THRESHOLD:-3}"
MAX_RESTART_ATTEMPTS="${MAX_RESTART_ATTEMPTS:-5}"
PULL_ON_BOOT="${PULL_ON_BOOT:-true}"
RECORDING_STATE_FILE="${SERVICES_DIR}/4-CAPTURE/config/recording-active-state.env"
RUNNING_INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

readonly SERVICE_NONE="none"

find_mqtt_dir() {
    for candidate in \
        "/home/*/Desktop/1-MQTT" \
        "/home/*/1-MQTT"; do
        for dir in $candidate; do
            if [[ -f "${dir}/mqtt_client.py" && -f "${dir}/venv/bin/python3" ]]; then
                echo "$dir"
                return 0
            fi
        done
    done
    return 1
}

MQTT_DIR=$(find_mqtt_dir) || {
    logger -t "$LOG_TAG" "FATAL: Cannot find MQTT directory"
    exit 1
}

VENV_PYTHON="${MQTT_DIR}/venv/bin/python3"
MQTT_HELPER="/opt/antscihub-pi-service-manager/services/mqtt_helper.py"

logger -t "$LOG_TAG" "MQTT_DIR=${MQTT_DIR}"

# --- Systemd notify -----------------------------------------------------------

notify_ready() {
    systemd-notify --ready 2>/dev/null || true
}

notify_watchdog() {
    systemd-notify WATCHDOG=1 2>/dev/null || true
}

# --- Wait for network ---------------------------------------------------------

logger -t "$LOG_TAG" "Waiting for network..."
for i in $(seq 1 30); do
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        logger -t "$LOG_TAG" "Network up after ${i}s"
        break
    fi
    sleep 1
done

notify_ready
logger -t "$LOG_TAG" "Notified systemd: ready"

# --- Start persistent MQTT connection -----------------------------------------
# FIX #1: Don't pipe coproc stdout into logger — that consumes the FDs and
#         makes $! point at logger instead of the Python process.
#         Instead, redirect only stderr to logger via process substitution,
#         and keep stdin/stdout connected to the coproc FDs.

MQTT_FD=""
MQTT_HELPER_PID=""

mqtt_helper_running() {
    [[ -n "${MQTT_HELPER_PID:-}" ]] || return 1
    kill -0 "$MQTT_HELPER_PID" 2>/dev/null || return 1

    local ppid
    ppid=$(ps -o ppid= -p "$MQTT_HELPER_PID" 2>/dev/null)
    ppid="${ppid//[[:space:]]/}"
    [[ -n "$ppid" && "$ppid" == "$$" ]]
}

stop_mqtt_helper() {
    if mqtt_helper_running; then
        kill "$MQTT_HELPER_PID" 2>/dev/null || true
    fi
    if [[ -n "${MQTT_HELPER_PID:-}" ]]; then
        wait "$MQTT_HELPER_PID" 2>/dev/null || true
    fi
    MQTT_HELPER_PID=""
    MQTT_FD=""
}

start_mqtt_helper() {
    logger -t "$LOG_TAG" "Starting MQTT helper..."
    coproc MQTT { "$VENV_PYTHON" "$MQTT_HELPER" 2> >(logger -t "$LOG_TAG"); }

    MQTT_FD=${MQTT[1]:-}
    MQTT_HELPER_PID=${MQTT_PID:-}   # bash sets MQTT_PID for the named coproc

    sleep 3

    if [[ -z "${MQTT_FD:-}" || -z "${MQTT_HELPER_PID:-}" ]]; then
        logger -t "$LOG_TAG" "WARN: MQTT helper started without valid FD/PID"
        return 1
    fi

    if ! mqtt_helper_running; then
        logger -t "$LOG_TAG" "WARN: MQTT helper failed to start"
        return 1
    fi

    logger -t "$LOG_TAG" "MQTT helper running (pid ${MQTT_HELPER_PID}, fd ${MQTT_FD})"
    return 0
}

ensure_mqtt_helper() {
    if mqtt_helper_running; then
        return 0
    fi

    logger -t "$LOG_TAG" "WARN: MQTT helper not running; attempting respawn"
    stop_mqtt_helper
    start_mqtt_helper
}

if ! start_mqtt_helper; then
    logger -t "$LOG_TAG" "FATAL: MQTT helper unavailable at startup"
    exit 1
fi

cleanup() {
    stop_mqtt_helper
}
trap cleanup EXIT

# --- Helpers ------------------------------------------------------------------

fix_permissions() {
    local dir="$1"
    find "$dir" -name "*.sh" -exec chmod +x {} + 2>/dev/null || true
}

clean_repo() {
    local dir="$1"
    git -C "$dir" checkout -- . 2>/dev/null || true
}

repo_branch() {
    local dir="${1%/}"
    local fallback="${2:-main}"
    local branch

    branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
        branch="$fallback"
    fi
    echo "$branch"
}

repo_remote() {
    local dir="${1%/}"
    git -C "$dir" remote get-url origin 2>/dev/null || true
}

git_common_dir() {
    local dir="${1%/}"
    local git_dir

    git_dir=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null || true)
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
    git_dir=$(git_common_dir "$dir")

    [[ -d "$git_dir" ]] || return 0

    # These pseudo-refs are safe to recreate and are common casualties after
    # interrupted pulls. A broken ORIG_HEAD can block otherwise healthy fetches.
    local ref_file
    for ref_file in ORIG_HEAD FETCH_HEAD MERGE_HEAD REBASE_HEAD CHERRY_PICK_HEAD; do
        if [[ -e "${git_dir}/${ref_file}" ]]; then
            logger -t "$LOG_TAG" "${dir}: removing transient git ref ${ref_file}"
            rm -f "${git_dir}/${ref_file}" 2>/dev/null || true
        fi
    done

    find "$git_dir" -type f -name "*.lock" -mmin +10 -print -delete 2>/dev/null \
        | while IFS= read -r lock_file; do
            logger -t "$LOG_TAG" "${dir}: removed stale git lock ${lock_file}"
        done
}

fetch_reset_repo() {
    local dir="${1%/}"
    local remote="$2"
    local branch="$3"

    [[ -n "$branch" ]] || branch="main"

    if [[ -n "$remote" ]]; then
        if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
            git -C "$dir" remote set-url origin "$remote" 2>/dev/null || true
        else
            git -C "$dir" remote add origin "$remote" 2>/dev/null || true
        fi
    fi

    remove_transient_git_refs "$dir"

    if ! git -C "$dir" fetch --prune origin "+refs/heads/${branch}:refs/remotes/origin/${branch}" 2>&1 | logger -t "$LOG_TAG"; then
        return 1
    fi
    if ! git -C "$dir" reset --hard "origin/${branch}" 2>&1 | logger -t "$LOG_TAG"; then
        return 1
    fi
    git -C "$dir" clean -fd 2>&1 | logger -t "$LOG_TAG" || true
    return 0
}

reclone_repo() {
    local dir="${1%/}"
    local remote="$2"
    local branch="$3"
    local reason="${4:-git repair failed}"

    [[ -n "$remote" ]] || remote=$(repo_remote "$dir")
    if [[ -z "$remote" ]]; then
        logger -t "$LOG_TAG" "${dir}: cannot reclone; no origin remote available"
        return 1
    fi

    local parent base abs_dir tmp_dir owner group
    parent=$(cd "$(dirname "$dir")" 2>/dev/null && pwd) || return 1
    base=$(basename "$dir")
    abs_dir="${parent}/${base}"

    if [[ "$abs_dir" == "$RUNNING_INSTALL_DIR" ]]; then
        logger -t "$LOG_TAG" "${dir}: refusing to reclone running install directory"
        return 1
    fi

    owner=$(stat -c '%U' "$abs_dir" 2>/dev/null || echo root)
    group=$(stat -c '%G' "$abs_dir" 2>/dev/null || echo root)
    tmp_dir=$(mktemp -d "${parent}/.${base}.reclone.XXXXXX") || return 1
    rmdir "$tmp_dir" 2>/dev/null || true

    logger -t "$LOG_TAG" "${dir}: recloning from ${remote} (${reason})"
    if [[ -n "$branch" ]]; then
        if ! git clone --branch "$branch" "$remote" "$tmp_dir" 2>&1 | logger -t "$LOG_TAG"; then
            rm -rf "$tmp_dir" 2>/dev/null || true
            tmp_dir=$(mktemp -d "${parent}/.${base}.reclone.XXXXXX") || return 1
            rmdir "$tmp_dir" 2>/dev/null || true
            if ! git clone "$remote" "$tmp_dir" 2>&1 | logger -t "$LOG_TAG"; then
                rm -rf "$tmp_dir" 2>/dev/null || true
                return 1
            fi
        fi
    elif ! git clone "$remote" "$tmp_dir" 2>&1 | logger -t "$LOG_TAG"; then
        rm -rf "$tmp_dir" 2>/dev/null || true
        return 1
    fi

    if [[ -e "$abs_dir" ]]; then
        logger -t "$LOG_TAG" "${dir}: removing broken checkout before reclone"
        if ! rm -rf "$abs_dir"; then
            logger -t "$LOG_TAG" "${dir}: failed to remove broken checkout"
            rm -rf "$tmp_dir" 2>/dev/null || true
            return 1
        fi
    fi
    if ! mv "$tmp_dir" "$abs_dir"; then
        logger -t "$LOG_TAG" "${dir}: failed to install repaired checkout"
        rm -rf "$tmp_dir" 2>/dev/null || true
        return 1
    fi

    if [[ -n "$owner" && "$owner" != "UNKNOWN" ]]; then
        chown -R "${owner}:${group}" "$abs_dir" 2>/dev/null || true
    fi
    logger -t "$LOG_TAG" "${dir}: replaced broken checkout with clean clone"
    return 0
}

pull_repo() {
    local dir="${1%/}"
    local remote="${2:-}"
    local branch="${3:-}"

    [[ -d "${dir}/.git" ]] || return 1

    [[ -n "$remote" ]] || remote=$(repo_remote "$dir")
    [[ -n "$branch" ]] || branch=$(repo_branch "$dir" "main")

    clean_repo "$dir"
    if git -C "$dir" pull --ff-only 2>&1 | logger -t "$LOG_TAG"; then
        fix_permissions "$dir"
        return 0
    fi

    logger -t "$LOG_TAG" "Pull failed for ${dir}, trying fetch/reset repair"
    if fetch_reset_repo "$dir" "$remote" "$branch"; then
        fix_permissions "$dir"
        return 0
    fi

    logger -t "$LOG_TAG" "Fetch/reset repair failed for ${dir}, trying reclone"
    if reclone_repo "$dir" "$remote" "$branch" "pull failed and refs could not be repaired"; then
        fix_permissions "$dir"
        return 0
    fi

    logger -t "$LOG_TAG" "Reclone failed for ${dir}, trying final reset/pull"
    remove_transient_git_refs "$dir"
    git -C "$dir" reset --hard HEAD 2>/dev/null || true
    git -C "$dir" clean -fd 2>/dev/null || true
    if git -C "$dir" pull --ff-only 2>&1 | logger -t "$LOG_TAG"; then
        fix_permissions "$dir"
        return 0
    fi
    return 1
}

mqtt_send() {
    local payload="$1"

    if ! ensure_mqtt_helper; then
        logger -t "$LOG_TAG" "WARN: mqtt_send dropped (helper unavailable)"
        return 1
    fi

    if echo "$payload" >&"$MQTT_FD" 2>/dev/null; then
        return 0
    fi

    logger -t "$LOG_TAG" "WARN: mqtt_send failed; retrying after helper respawn"
    stop_mqtt_helper
    if ensure_mqtt_helper && echo "$payload" >&"$MQTT_FD" 2>/dev/null; then
        logger -t "$LOG_TAG" "MQTT send recovered after helper respawn"
        return 0
    fi

    logger -t "$LOG_TAG" "WARN: mqtt_send failed after respawn"
    return 1
}

report() {
    local event="$1"
    shift
    local extra_json="$1"
    local timestamp
    timestamp=$(date +%s.%3N)

    logger -t "$LOG_TAG" "${event}: ${extra_json}"
    mqtt_send "{\"schema\":\"fleet.service-manager.v1\",\"event\":\"${event}\",\"device_id\":\"${DEVICE_ID}\",\"timestamp\":${timestamp},${extra_json}}"
}

report_status() {
    local json_payload="$1"
    report "status" "${json_payload}"
}

recording_active_json_bool() {
    if [[ -f "$RECORDING_STATE_FILE" ]]; then
        echo "true"
    else
        echo "false"
    fi
}

system_metrics_json() {
    # Read from procfs/sysfs with shell builtins only (no extra subprocesses).
    local load1="null"
    local load5="null"
    local load15="null"
    local mem_available_kb="null"
    local mem_total_kb="null"
    local mem_available_pct="null"
    local cpu_temp_c="null"

    if [[ -r /proc/loadavg ]]; then
        local l1 l5 l15 rest
        if read -r l1 l5 l15 rest < /proc/loadavg; then
            load1="$l1"
            load5="$l5"
            load15="$l15"
        fi
    fi

    if [[ -r /proc/meminfo ]]; then
        local key value unit
        local mem_avail_val=0
        local mem_total_val=0

        while read -r key value unit; do
            case "$key" in
                MemAvailable:) mem_avail_val=$value ;;
                MemTotal:) mem_total_val=$value ;;
            esac

            if [[ "$mem_avail_val" -gt 0 && "$mem_total_val" -gt 0 ]]; then
                break
            fi
        done < /proc/meminfo

        if [[ "$mem_avail_val" -gt 0 ]]; then
            mem_available_kb="$mem_avail_val"
        fi
        if [[ "$mem_total_val" -gt 0 ]]; then
            mem_total_kb="$mem_total_val"
        fi
        if [[ "$mem_avail_val" -gt 0 && "$mem_total_val" -gt 0 ]]; then
            mem_available_pct=$(( (mem_avail_val * 100) / mem_total_val ))
        fi
    fi

    if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
        local temp_raw
        if read -r temp_raw < /sys/class/thermal/thermal_zone0/temp; then
            if [[ "$temp_raw" =~ ^[0-9]+$ ]]; then
                if [[ "$temp_raw" -ge 1000 ]]; then
                    cpu_temp_c="$((temp_raw / 1000)).$(((temp_raw % 1000) / 100))"
                else
                    cpu_temp_c="$temp_raw"
                fi
            fi
        fi
    fi

    echo "\"load_avg_1m\":${load1},\"load_avg_5m\":${load5},\"load_avg_15m\":${load15},\"ram_available_kb\":${mem_available_kb},\"ram_total_kb\":${mem_total_kb},\"ram_available_pct\":${mem_available_pct},\"cpu_core_temp_c\":${cpu_temp_c}"
}

array_to_json() {
    # FIX #8: accept the array name but guard against empty / missing
    local arr_name="$1"
    local -n _arr_ref="$arr_name" 2>/dev/null || { echo "[]"; return; }
    if [[ ${#_arr_ref[@]} -eq 0 ]]; then
        echo "[]"
        return
    fi
    local json_array
    json_array=$(printf '"%s",' "${_arr_ref[@]}")
    echo "[${json_array%,}]"
}

parse_manifest() {
    local manifest_path="$1"
    local -n _out="$2"

    _out=()
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        _out["$key"]="$value"
    done < "$manifest_path"
}

# FIX #3: discover_services now uses null-delimited output so paths with
#         spaces are handled correctly.
cleanup_generated_broken_repos() {
    find "${SERVICES_DIR}" \
        \( -type d \( -name "*.broken-*" -o -name ".*.reclone.*" \) -prune \) \
        -exec rm -rf {} + 2>/dev/null || true
}

discover_services() {
    find "${SERVICES_DIR}" \
        \( -type d \( -name "*.broken-*" -o -name ".*.reclone.*" \) -prune \) -o \
        \( -name "antscihub.manifest" -type f -print0 \) 2>/dev/null \
        | while IFS= read -r -d '' manifest; do
            printf '%s\0' "$(dirname "$manifest")/"
        done
}

service_unit_needs_reinstall() {
    local svc="$1"
    local folder_name="$2"

    [[ -n "$svc" && "$svc" != "$SERVICE_NONE" ]] || return 1

    if ! systemctl cat "$svc" &>/dev/null; then
        logger -t "$LOG_TAG" "${folder_name}: service not installed, running install"
        return 0
    fi

    local unit_text
    unit_text=$(systemctl cat "$svc" --no-pager 2>/dev/null || true)
    if printf '%s\n' "$unit_text" | grep -Eq '\.broken-[0-9]{8}-[0-9]{6}|\.reclone\.'; then
        logger -t "$LOG_TAG" "${folder_name}: ${svc} unit references generated duplicate path, reinstalling"
        report "service_unit_repair" "\"service\":\"${svc}\",\"folder\":\"${folder_name}\",\"reason\":\"unit references generated duplicate path\""
        return 0
    fi

    return 1
}

# FIX #5: capture the real exit code of the install command via PIPESTATUS
run_install() {
    local dir="$1"
    local install_cmd="$2"
    local folder_name="$3"
    local svc="$4"
    local reason="${5:-update}"

    fix_permissions "$dir"
    logger -t "$LOG_TAG" "Running install for ${folder_name}: ${install_cmd}"
    notify_watchdog

    (cd "$dir" && bash -c "$install_cmd") 2>&1 | logger -t "$LOG_TAG"
    local exit_code=${PIPESTATUS[0]}

    if [[ "$exit_code" -eq 0 ]]; then
        report "service_install_done" "\"success\":true,\"service\":\"${folder_name}\",\"cmd\":\"${install_cmd}\",\"reason\":\"${reason}\""
        if [[ -n "$svc" && "$svc" != "$SERVICE_NONE" ]]; then
            systemctl restart "$svc" 2>&1 | logger -t "$LOG_TAG" || true
        fi
        return 0
    else
        report "service_install_done" "\"success\":false,\"service\":\"${folder_name}\",\"cmd\":\"${install_cmd}\",\"exit_code\":${exit_code}"
        return 1
    fi
}

# --- Clone missing modules from modules.conf ---------------------------------

clone_missing_modules() {
    local modules_conf="${SELF_REPO_DIR}/config/modules.conf"

    if [[ ! -f "$modules_conf" ]]; then
        logger -t "$LOG_TAG" "No modules.conf found at ${modules_conf}"
        return
    fi

    # FIX #11: resolve home safely via getent, no eval
    local real_user real_home
    real_user=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}')
    real_home=$(getent passwd "$real_user" | cut -d: -f6)

    logger -t "$LOG_TAG" "Checking modules.conf for new repos..."

    while IFS='|' read -r repo_url target_path; do
        [[ "$repo_url" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${repo_url// /}" ]] && continue

        repo_url=$(echo "$repo_url" | xargs)
        target_path=$(echo "$target_path" | xargs)
        [[ -z "$target_path" ]] && continue

        # Expand ~ and $HOME
        case "$target_path" in
            '~/'*)
                target_path="${real_home}/${target_path:2}"
                ;;
            "\$HOME/"*)
                target_path="${real_home}/${target_path#\$HOME/}"
                ;;
            "\${HOME}/"*)
                target_path="${real_home}/${target_path#\${HOME}/}"
                ;;
        esac

        local branch="main"
        if [[ -f "${target_path}/antscihub.manifest" ]]; then
            unset existing_manifest
            local -A existing_manifest
            parse_manifest "${target_path}/antscihub.manifest" existing_manifest
            branch="${existing_manifest[GIT_BRANCH]:-main}"
        fi

        # Existing modules are still updated here so a deleted or corrupt
        # manifest can be restored before discovery scans SERVICES_DIR.
        if [[ -d "${target_path}/.git" ]]; then
            logger -t "$LOG_TAG" "Module exists, updating/repairing ${target_path}"
            if pull_repo "$target_path" "$repo_url" "$branch"; then
                report "module_update_done" "\"success\":true,\"repo\":\"${repo_url}\",\"path\":\"${target_path}\""
            else
                report "module_update_done" "\"success\":false,\"repo\":\"${repo_url}\",\"path\":\"${target_path}\""
            fi
            continue
        fi

        logger -t "$LOG_TAG" "New module: cloning ${repo_url} → ${target_path}"
        notify_watchdog

        mkdir -p "$(dirname "$target_path")"

        if git clone "$repo_url" "$target_path" 2>&1 | logger -t "$LOG_TAG"; then
            report "module_cloned" "\"success\":true,\"repo\":\"${repo_url}\",\"path\":\"${target_path}\""
            fix_permissions "$target_path"

            # Fix ownership
            if id -u "${real_user}" >/dev/null 2>&1; then
                chown -R "${real_user}:${real_user}" "${target_path}" 2>/dev/null || true
            fi

            # Run install if manifest exists
            if [[ -f "${target_path}/antscihub.manifest" ]]; then
                # FIX #4: unset before re-declaring
                unset new_manifest
                local -A new_manifest
                parse_manifest "${target_path}/antscihub.manifest" new_manifest

                local install_cmd="${new_manifest[INSTALL_CMD]:-}"
                local svc="${new_manifest[SERVICE_NAME]:-}"
                local folder_name
                folder_name=$(basename "$target_path")

                if [[ -n "$install_cmd" && "$install_cmd" != "$SERVICE_NONE" ]]; then
                    run_install "$target_path" "$install_cmd" "$folder_name" "$svc" "first_install"
                fi
            fi
        else
            report "module_cloned" "\"success\":false,\"repo\":\"${repo_url}\",\"path\":\"${target_path}\""
        fi

    done < "$modules_conf"
}

# --- State tracking -----------------------------------------------------------

declare -A FAIL_COUNTS
declare -A RESTART_ATTEMPTS
declare -A GAVE_UP

# --- Boot phase ---------------------------------------------------------------
# Startup-only update/install pass.
# This runs when the service starts (boot or manual restart), not every loop.

boot_update() {
    if [[ "$PULL_ON_BOOT" != "true" ]]; then
        logger -t "$LOG_TAG" "PULL_ON_BOOT disabled, skipping"
        return
    fi

    notify_watchdog
    logger -t "$LOG_TAG" "Boot phase: pulling repos..."
    report "boot_update_start" "\"services_dir\":\"${SERVICES_DIR}\""

    # Self-update
    local self_dir="${SELF_REPO_DIR:-/opt/antscihub-pi-service-manager}"
    if [[ -d "${self_dir}/.git" ]]; then
        local old_head new_head
        old_head=$(git -C "$self_dir" rev-parse HEAD 2>/dev/null || echo "unknown")

        notify_watchdog
        if pull_repo "$self_dir" "$(repo_remote "$self_dir")" "$(repo_branch "$self_dir" "main")"; then
            new_head=$(git -C "$self_dir" rev-parse HEAD 2>/dev/null || echo "unknown")
            if [[ "$old_head" != "$new_head" ]]; then
                report "self_update_done" "\"success\":true,\"old\":\"${old_head:0:8}\",\"new\":\"${new_head:0:8}\",\"source\":\"${self_dir}\""
                logger -t "$LOG_TAG" "Self-updated, re-running install.sh..."
                if SELF_REINSTALL=true bash "${self_dir}/install.sh" 2>&1 | logger -t "$LOG_TAG"; then
                    report "self_reinstalled" "\"head\":\"${new_head:0:8}\""
                    # FIX #7: cleanup trap will fire on exit and properly stop MQTT helper
                    sleep 2
                    exit 0
                else
                    report "self_reinstall_failed" "\"head\":\"${new_head:0:8}\",\"success\":false"
                    logger -t "$LOG_TAG" "Self-update install.sh failed; continuing with current process"
                fi
            fi
        else
            report "self_update_done" "\"success\":false,\"error\":\"git pull failed\",\"dir\":\"${self_dir}\""
        fi
    else
        logger -t "$LOG_TAG" "Self-update repo not found at ${self_dir}; skipping"
    fi

    cleanup_generated_broken_repos
    # Clone any new modules from modules.conf
    clone_missing_modules

    # FIX #3: read null-delimited service directories
    while IFS= read -r -d '' dir; do
        notify_watchdog

        # FIX #4: unset before re-declaring to avoid stale keys
        unset manifest
        local -A manifest
        # FIX #6: use explicit / separator (double slash is harmless)
        parse_manifest "${dir}/antscihub.manifest" manifest

        local svc="${manifest[SERVICE_NAME]:-}"
        local remote="${manifest[GIT_REMOTE]:-}"
        local install_cmd="${manifest[INSTALL_CMD]:-}"
        local folder_name
        folder_name=$(basename "$dir")

        local branch="${manifest[GIT_BRANCH]:-}"
        if [[ -z "$remote" ]]; then
            remote=$(repo_remote "$dir")
            if [[ -n "$remote" ]]; then
                logger -t "$LOG_TAG" "${folder_name}: manifest missing GIT_REMOTE, using origin ${remote} for repair"
                report "service_manifest_invalid" "\"service\":\"${folder_name}\",\"error\":\"missing GIT_REMOTE\",\"repair\":\"using_origin\""
            else
                logger -t "$LOG_TAG" "No GIT_REMOTE or origin remote in ${folder_name}, skipping"
                report "service_manifest_invalid" "\"service\":\"${folder_name}\",\"error\":\"missing GIT_REMOTE and origin\""
                continue
            fi
        fi

        if [[ ! -d "${dir}/.git" ]]; then
            logger -t "$LOG_TAG" "${folder_name} not a git repo, skipping"
            continue
        fi
        [[ -n "$branch" ]] || branch=$(repo_branch "$dir" "main")

        local old_head new_head
        old_head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "unknown")

        notify_watchdog
        if pull_repo "$dir" "$remote" "$branch"; then
            unset manifest
            local -A manifest
            parse_manifest "${dir}/antscihub.manifest" manifest
            svc="${manifest[SERVICE_NAME]:-}"
            remote="${manifest[GIT_REMOTE]:-$remote}"
            install_cmd="${manifest[INSTALL_CMD]:-}"

            if [[ -z "$svc" ]]; then
                logger -t "$LOG_TAG" "${folder_name}: manifest missing SERVICE_NAME after repair, skipping health install checks"
                report "service_manifest_invalid" "\"service\":\"${folder_name}\",\"error\":\"missing SERVICE_NAME after repair\""
                continue
            fi

            new_head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "unknown")

            if [[ "$old_head" != "$new_head" ]]; then
                report "service_update_done" "\"success\":true,\"service\":\"${folder_name}\",\"old\":\"${old_head:0:8}\",\"new\":\"${new_head:0:8}\""

                if [[ -n "$install_cmd" && "$install_cmd" != "$SERVICE_NONE" ]]; then
                    run_install "$dir" "$install_cmd" "$folder_name" "$svc" "update"
                fi
            else
                logger -t "$LOG_TAG" "${folder_name}: up to date (${old_head:0:8})"

                if service_unit_needs_reinstall "$svc" "$folder_name"; then
                    if [[ -n "$install_cmd" && "$install_cmd" != "$SERVICE_NONE" ]]; then
                        run_install "$dir" "$install_cmd" "$folder_name" "$svc" "repair_unit"
                    fi
                fi
            fi
        else
            report "service_update_done" "\"success\":false,\"error\":\"git pull failed\",\"service\":\"${folder_name}\",\"remote\":\"${remote}\""
        fi
    done < <(discover_services)

    report "boot_update_done" "\"status\":\"complete\""
}

# --- Health check loop --------------------------------------------------------

check_services() {
    local managed=()
    local healthy=()
    local unhealthy=()

    # FIX #3: read null-delimited service directories
    while IFS= read -r -d '' dir; do
        # FIX #4: unset before re-declaring to avoid stale keys
        unset manifest
        local -A manifest
        # FIX #6: use explicit / separator
        parse_manifest "${dir}/antscihub.manifest" manifest

        local svc="${manifest[SERVICE_NAME]:-}"
        local no_restart="${manifest[NO_AUTO_RESTART]:-false}"
        local grace="${manifest[STARTUP_GRACE]:-10}"
        local folder_name
        folder_name=$(basename "$dir")

        if [[ -z "$svc" || "$svc" == "$SERVICE_NONE" ]]; then
            continue
        fi

        managed+=("$svc")

        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            healthy+=("$svc")
            FAIL_COUNTS["$svc"]=0
            RESTART_ATTEMPTS["$svc"]=0
            GAVE_UP["$svc"]=0
            continue
        fi

        local fails=${FAIL_COUNTS["$svc"]:-0}
        fails=$((fails + 1))
        FAIL_COUNTS["$svc"]=$fails

        if [[ "${GAVE_UP["$svc"]:-0}" == "1" ]]; then
            unhealthy+=("$svc")
            continue
        fi

        if [[ "$no_restart" == "true" ]]; then
            report "service_down" "\"service\":\"${svc}\",\"folder\":\"${folder_name}\",\"auto_restart\":false,\"consecutive_failures\":${fails}"
            unhealthy+=("$svc")
            continue
        fi

        if [[ "$fails" -ge "$RESTART_THRESHOLD" ]]; then
            local attempts=${RESTART_ATTEMPTS["$svc"]:-0}
            attempts=$((attempts + 1))
            RESTART_ATTEMPTS["$svc"]=$attempts

            if [[ "$attempts" -gt "$MAX_RESTART_ATTEMPTS" ]]; then
                GAVE_UP["$svc"]=1
                report "service_gave_up" "\"service\":\"${svc}\",\"folder\":\"${folder_name}\",\"restart_attempts\":${attempts}"
                unhealthy+=("$svc")
                continue
            fi

            report "service_restart" "\"service\":\"${svc}\",\"folder\":\"${folder_name}\",\"reason\":\"consecutive failures: ${fails}\",\"attempt\":${attempts}"

            if systemctl restart "$svc" 2>&1 | logger -t "$LOG_TAG"; then
                FAIL_COUNTS["$svc"]=0
                sleep "$grace"

                if systemctl is-active --quiet "$svc" 2>/dev/null; then
                    report "service_recovered" "\"service\":\"${svc}\",\"folder\":\"${folder_name}\",\"attempt\":${attempts}"
                    RESTART_ATTEMPTS["$svc"]=0
                    healthy+=("$svc")
                    continue
                else
                    report "service_restart_failed" "\"service\":\"${svc}\",\"folder\":\"${folder_name}\",\"attempt\":${attempts}"
                    unhealthy+=("$svc")
                fi
            else
                report "service_restart_error" "\"service\":\"${svc}\",\"folder\":\"${folder_name}\",\"attempt\":${attempts}"
                unhealthy+=("$svc")
            fi
        else
            logger -t "$LOG_TAG" "${svc} not active (failure ${fails}/${RESTART_THRESHOLD})"
            unhealthy+=("$svc")
        fi
    done < <(discover_services)

    local managed_json
    local healthy_json
    local unhealthy_json
    local recording_json
    local metrics_json

    managed_json=$(array_to_json managed)
    healthy_json=$(array_to_json healthy)
    unhealthy_json=$(array_to_json unhealthy)
    recording_json=$(recording_active_json_bool)
    metrics_json=$(system_metrics_json)

    report_status "\"managed\":${managed_json},\"healthy\":${healthy_json},\"unhealthy\":${unhealthy_json},\"recording\":${recording_json},${metrics_json}"
}

# --- Entrypoint ---------------------------------------------------------------

logger -t "$LOG_TAG" "Starting service-manager (pid $$)"
report "boot_start" "\"services_dir\":\"${SERVICES_DIR}\",\"check_interval\":${CHECK_INTERVAL}"

# Boot phase (one-shot startup pass)
boot_update

# Monitor loop: steady-state health checks only (no git pull/install pass here)
while true; do
    notify_watchdog
    check_services
    sleep "$CHECK_INTERVAL"
done
