#!/usr/bin/env bash
# system-guard.sh
# Usage:
#   sudo ./system-guard.sh --install     Install/update as systemd service (idempotent)
#   sudo ./system-guard.sh --uninstall   Remove service, script (idempotent, asks re: logs/config)
#   ./system-guard.sh                    Run the guard daemon directly (systemd calls this, no flag)
#   ./system-guard.sh --dry-run          Run daemon, log actions only, kill/hibernate nothing

set -uo pipefail

# ---------- paths ----------
SELF="$(readlink -f "$0")"
INSTALL_DEST="/usr/local/bin/system-guard.sh"
SERVICE_FILE="/etc/systemd/system/system-guard.service"
SERVICE_NAME="system-guard.service"
if [[ $EUID -eq 0 ]]; then
    LOGFILE="/var/log/system-guard.log"
else
    LOGFILE="${XDG_STATE_HOME:-$HOME/.local/state}/system-guard.log"
    mkdir -p "$(dirname "$LOGFILE")"
fiCONF_DIR="/etc/system-guard"
PROTECTED_FILE="${CONF_DIR}/protected.conf"
LOGROTATE_FILE="/etc/logrotate.d/system-guard"

# ---------- tunables ----------
MEM_THRESHOLD=8          # % RAM available considered critical
MEM_CHECK_INTERVAL=5
MEM_COOLDOWN=10
RECENT_WINDOW=300        # seconds - "recently started" window for victim selection

BAT_THRESHOLD=15
BAT_CHECK_INTERVAL=30
POPUP_TIMEOUT=60

SUPERVISOR_INTERVAL=15

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

DEFAULT_PROTECTED="systemd
init
kthreadd
Xorg
Xwayland
gnome-shell
plasmashell
sshd
NetworkManager
system-guard.sh
bash
zsh
dbus-daemon
containerd-shim
dockerd
docker-proxy"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] ${*:2}" >> "$LOGFILE"; }

load_protected() {
    if [[ -f "$PROTECTED_FILE" ]]; then
        grep -vE '^\s*(#|$)' "$PROTECTED_FILE"
    else
        echo "$DEFAULT_PROTECTED"
    fi
}

is_protected() {
    local name="$1"
    while read -r p; do
        [[ "$name" == "$p" ]] && return 0
    done < <(load_protected)
    return 1
}

# ---------- memory guard (fix #1: RSS-based victim, recency as tiebreak) ----------
get_mem_available_pct() {
    local total avail
    total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    echo $(( avail * 100 / total ))
}

pick_victim() {
    # Prefer the largest-RSS process that started within RECENT_WINDOW seconds
    # (most likely the actual cause of the spike). If nothing recent qualifies,
    # fall back to the single largest-RSS process system-wide.
    local recent_victim="" fallback_victim=""
    while read -r pid rss etimes comm; do
        [[ "$comm" =~ ^\[.*\]$ ]] && continue   # kernel threads
        is_protected "$comm" && continue
        [[ "$pid" -eq $$ ]] && continue

        [[ -z "$fallback_victim" ]] && fallback_victim="$pid $rss $etimes $comm"
        if [[ -z "$recent_victim" && "$etimes" -le "$RECENT_WINDOW" ]]; then
            recent_victim="$pid $rss $etimes $comm"
            break
        fi
    done < <(ps -eo pid,rss,etimes,comm --no-headers --sort=-rss)

    [[ -n "$recent_victim" ]] && echo "$recent_victim" || echo "$fallback_victim"
}

kill_offender() {
    local victim pid rss etimes comm
    victim=$(pick_victim)
    if [[ -z "$victim" ]]; then
        log MEM "Memory critical but no killable process found"
        return
    fi
    read -r pid rss etimes comm <<< "$victim"

    if [[ "$DRY_RUN" == true ]]; then
        log MEM "[DRY-RUN] Would kill PID $pid ($comm), RSS=${rss}KB, started ${etimes}s ago"
        return
    fi

    log MEM "Killing PID $pid ($comm), RSS=${rss}KB, started ${etimes}s ago"
    kill -TERM "$pid" 2>/dev/null
    sleep 2
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
}

mem_guard() {
    log MEM "started (threshold=${MEM_THRESHOLD}%, recent_window=${RECENT_WINDOW}s, dry_run=$DRY_RUN)"
    while true; do
        pct=$(get_mem_available_pct)
        if (( pct < MEM_THRESHOLD )); then
            log MEM "Available memory ${pct}% below threshold"
            kill_offender
            sleep "$MEM_COOLDOWN"
        fi
        sleep "$MEM_CHECK_INTERVAL"
    done
}

# ---------- battery guard (fix #6: distinguish popup failure vs no-response) ----------
detect_battery_path() {
    for bat in /sys/class/power_supply/BAT*; do
        [[ -d "$bat" ]] && { echo "$bat"; return; }
    done
    echo ""
}

get_active_gui_user() {
    loginctl list-sessions --no-legend | awk '{print $3}' | while read -r u; do
        sid=$(loginctl list-sessions --no-legend | awk -v u="$u" '$3==u{print $1}')
        if loginctl show-session "$sid" -p Type 2>/dev/null | grep -qE 'x11|wayland'; then
            echo "$u"; return
        fi
    done
}

show_popup_as_user() {
    local user="$1" uid out rc
    uid=$(id -u "$user")
    out=$(sudo -u "$user" DISPLAY=":0" XAUTHORITY="/home/${user}/.Xauthority" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
        zenity --question \
        --title="Battery Low (${BAT_THRESHOLD}%)" \
        --text="Battery is at ${BAT_THRESHOLD}%. PC will hibernate automatically.\nStop hibernation?" \
        --timeout="$POPUP_TIMEOUT" 2>&1)
    rc=$?
    echo "${rc}|${out}"
}

do_hibernate() {
    if [[ "$DRY_RUN" == true ]]; then
        log BAT "[DRY-RUN] Would hibernate now."
    else
        log BAT "Hibernating now."
        systemctl hibernate
    fi
}

battery_guard() {
    local bat_path
    bat_path=$(detect_battery_path)
    if [[ -z "$bat_path" ]]; then
        log BAT "No battery found on this system. battery_guard exiting."
        return
    fi
    log BAT "started using $bat_path (threshold=${BAT_THRESHOLD}%, dry_run=$DRY_RUN)"

    local already_handled=false
    while true; do
        status=$(cat "${bat_path}/status" 2>/dev/null || echo "Unknown")
        capacity=$(cat "${bat_path}/capacity" 2>/dev/null || echo 100)

        if [[ "$status" == "Discharging" && "$capacity" -le "$BAT_THRESHOLD" ]]; then
            if [[ "$already_handled" == false ]]; then
                already_handled=true
                log BAT "Battery at ${capacity}%, prompting user"
                user=$(get_active_gui_user)

                if [[ -z "$user" ]]; then
                    log BAT "No active GUI session found. Hibernating without prompt."
                    do_hibernate
                else
                    result=$(show_popup_as_user "$user")
                    rc="${result%%|*}"
                    errout="${result#*|}"
                    case "$rc" in
                        0) log BAT "User chose to stop hibernation." ;;
                        1) log BAT "User declined - hibernating." ; do_hibernate ;;
                        5) log BAT "Popup timed out with no response - hibernating." ; do_hibernate ;;
                        *) log BAT "Popup failed to display (rc=$rc): ${errout:-none} - treating as no-response, hibernating." ; do_hibernate ;;
                    esac
                fi
            fi
        else
            already_handled=false
        fi
        sleep "$BAT_CHECK_INTERVAL"
    done
}

# ---------- supervisor (fix #4) ----------
run_daemon() {
    log MAIN "system-guard starting (dry_run=$DRY_RUN)"
    mem_guard & MEM_PID=$!
    battery_guard & BAT_PID=$!

    trap 'log MAIN "Stop signal received, terminating child jobs"; kill "$MEM_PID" "$BAT_PID" 2>/dev/null; exit 0' SIGTERM SIGINT

    while true; do
        if ! kill -0 "$MEM_PID" 2>/dev/null; then
            log MAIN "mem_guard (PID $MEM_PID) died - restarting it"
            mem_guard & MEM_PID=$!
        fi
        if ! kill -0 "$BAT_PID" 2>/dev/null; then
            log MAIN "battery_guard (PID $BAT_PID) died - restarting it"
            battery_guard & BAT_PID=$!
        fi
        sleep "$SUPERVISOR_INTERVAL"
    done
}

# ---------- install ----------
do_install() {
    [[ $EUID -ne 0 ]] && { echo "Run with sudo: sudo $0 --install"; exit 1; }

    command -v zenity >/dev/null 2>&1 \
        && echo "[install] zenity already installed, skipping." \
        || { echo "[install] installing zenity..."; apt update -qq && apt install -y zenity; }

    mkdir -p "$CONF_DIR"
    if [[ -f "$PROTECTED_FILE" ]]; then
        echo "[install] $PROTECTED_FILE already exists, leaving it alone."
    else
        echo "$DEFAULT_PROTECTED" > "$PROTECTED_FILE"
        echo "[install] Seeded $PROTECTED_FILE"
    fi

    if [[ -f "$INSTALL_DEST" ]] && cmp -s "$SELF" "$INSTALL_DEST"; then
        echo "[install] script already installed and up to date, skipping."
    else
        [[ -f "$INSTALL_DEST" ]] && cp "$INSTALL_DEST" "${INSTALL_DEST}.bak" \
            && echo "[install] backed up old copy to ${INSTALL_DEST}.bak"
        cp "$SELF" "$INSTALL_DEST"
        chmod +x "$INSTALL_DEST"
        echo "[install] Installed to $INSTALL_DEST"
    fi

    [[ -f "$LOGFILE" ]] && echo "[install] logfile already exists, skipping." \
        || { touch "$LOGFILE"; chmod 644 "$LOGFILE"; echo "[install] Created $LOGFILE"; }

    if [[ -f "$LOGROTATE_FILE" ]]; then
        echo "[install] logrotate config already exists, skipping."
    else
        cat > "$LOGROTATE_FILE" <<EOF
$LOGFILE {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF
        echo "[install] Created $LOGROTATE_FILE"
    fi

    local unit_content
    unit_content="[Unit]
Description=System guard - memory watchdog + battery hibernation prompt
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DEST}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
"
    local need_reload=false
    if [[ -f "$SERVICE_FILE" ]] && diff -q <(echo "$unit_content") "$SERVICE_FILE" >/dev/null 2>&1; then
        echo "[install] unit file already up to date, skipping."
    else
        echo "$unit_content" > "$SERVICE_FILE"
        echo "[install] Wrote $SERVICE_FILE"
        need_reload=true
    fi

    if [[ "$need_reload" == true ]]; then
        systemctl daemon-reload
        echo "[install] Ran daemon-reload"
    fi

    systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null \
        && echo "[install] service already enabled, skipping." \
        || { systemctl enable "$SERVICE_NAME"; echo "[install] Enabled $SERVICE_NAME"; }

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        if [[ "$need_reload" == true ]]; then
            systemctl restart "$SERVICE_NAME"
            echo "[install] Config changed - restarted service."
        else
            echo "[install] Service already running, no restart needed."
        fi
    else
        systemctl start "$SERVICE_NAME"
        echo "[install] Started $SERVICE_NAME"
    fi

    echo "[install] Done."
    systemctl --no-pager status "$SERVICE_NAME"
}

# ---------- uninstall ----------
do_uninstall() {
    [[ $EUID -ne 0 ]] && { echo "Run with sudo: sudo $0 --uninstall"; exit 1; }

    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl stop "$SERVICE_NAME"; echo "[uninstall] Stopped service."
    else
        echo "[uninstall] Service not running, skipping."
    fi

    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl disable "$SERVICE_NAME"; echo "[uninstall] Disabled service."
    else
        echo "[uninstall] Service not enabled, skipping."
    fi

    if [[ -f "$SERVICE_FILE" ]]; then
        rm -f "$SERVICE_FILE"; systemctl daemon-reload
        echo "[uninstall] Removed unit file."
    else
        echo "[uninstall] Unit file already absent, skipping."
    fi

    if [[ -f "$INSTALL_DEST" ]]; then
        rm -f "$INSTALL_DEST"; echo "[uninstall] Removed $INSTALL_DEST"
    else
        echo "[uninstall] $INSTALL_DEST already absent, skipping."
    fi

    if [[ -f "$LOGROTATE_FILE" ]]; then
        rm -f "$LOGROTATE_FILE"; echo "[uninstall] Removed logrotate config."
    fi

    if [[ -f "$PROTECTED_FILE" ]]; then
        read -rp "Remove $PROTECTED_FILE too? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] && rm -f "$PROTECTED_FILE" && echo "[uninstall] Removed config." \
            || echo "[uninstall] Kept config."
    fi

    if [[ -f "$LOGFILE" ]]; then
        read -rp "Remove logfile $LOGFILE too? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] && rm -f "$LOGFILE" && echo "[uninstall] Removed logfile." \
            || echo "[uninstall] Kept logfile."
    fi

    echo "[uninstall] Done."
}

# ---------- entry point ----------
case "${1:-}" in
    --install)   do_install ;;
    --uninstall) do_uninstall ;;
    --dry-run)   run_daemon ;;
    "")          run_daemon ;;
    *) echo "Usage: $0 [--install|--uninstall|--dry-run]"; exit 1 ;;
esac
