#!/usr/bin/env bash
# Install: sudo cp vacuum /usr/local/bin/vacuum && sudo chmod +x /usr/local/bin/vacuum && sudo vacuum -I

set -euo pipefail

# -- Configuration Defaults ----------------------------------------------------
DEFAULT_THRESHOLD=85
DEFAULT_AGGRESSIVE=95
DEFAULT_LOAD=4.0
DEFAULT_INTERVAL=60
DEFAULT_NOTIFY=true

THRESHOLD=$DEFAULT_THRESHOLD
AGGRESSIVE_THRESHOLD=$DEFAULT_AGGRESSIVE
LOAD_THRESHOLD=$DEFAULT_LOAD
MONITOR_INTERVAL=$DEFAULT_INTERVAL
NOTIFY=$DEFAULT_NOTIFY

JOURNAL_LIMIT="100M"
JOURNAL_DAYS=14
CACHE_AGE_DAYS=30
LOG_TAG="vacuum"
LOG_FILE="/var/log/vacuum.log"
REPORT_DIR="/var/log/vacuum-reports"
EXCLUDE_USERS="root"

[[ -f /etc/vacuum.conf ]] && source /etc/vacuum.conf

# -- Text-Based UI -------------------------------------------------------------
if [[ -t 1 ]] && tput colors &>/dev/null; then
    c_bld=$'\e[1m'; c_dim=$'\e[2m'; c_rst=$'\e[0m'
    c_blu=$'\e[34m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_red=$'\e[31m'; c_cyn=$'\e[36m'
else
    c_bld=''; c_dim=''; c_rst=''; c_blu=''; c_grn=''; c_ylw=''; c_red=''; c_cyn=''
fi

_hr()    { printf "${c_dim}%$(tput cols 2>/dev/null || echo 70)s${c_rst}\n" "" | tr ' ' '-'; }
_hr2()   { printf "${c_dim}%$(tput cols 2>/dev/null || echo 70)s${c_rst}\n" "" | tr ' ' '='; }
_hdr()   { clear; echo; _hr2; printf " ${c_bld}VACUUM ${c_rst} -- System Optimizer\n"; _hr2; echo; }
_title() { printf "\n ::: ${c_bld}${c_blu}%s${c_rst}\n" "$1"; _hr; }
_ok()    { printf " [OK]  %s\n" "$*"; }
_err()   { printf " [ER]  ${c_red}%s${c_rst}\n" "$*" >&2; }
_warn()  { printf " [WN]  ${c_ylw}%s${c_rst}\n" "$*"; }
_step()  { printf " [>>]  %-40s" "$1..."; }
_done()  { printf "${c_grn}Done${c_rst}\n"; }
_kv()    { printf "  %-30s : %s\n" "$1" "$2"; }

_bar() {
    local p="${1:-0}"
    local w=30
    local f=$(( p * w / 100 ))
    local e=$(( w - f ))
    local c="$c_grn"
    
    [[ $p -ge 75 ]] && c="$c_ylw"
    [[ $p -ge 90 ]] && c="$c_red"
    
    local filled=""
    local empty=""
    
    [[ $f -gt 0 ]] && filled=$(printf "%${f}s" "" | tr ' ' '#')
    [[ $e -gt 0 ]] && empty=$(printf "%${e}s" "" | tr ' ' '.')
    
    printf "${c}[%s%s]${c_rst} %3d%%" "$filled" "$empty" "$p"
}

_root() { [[ $EUID -eq 0 ]] || { _err "Root privileges required (use sudo)."; exit 1; }; }

# -- Bulletproof Notification Engine -------------------------------------------
_notify() {
    [[ "${NOTIFY:-true}" == "true" ]] || return 0
    local title="$1" body="$2"
    local user uid dbus
    
    user=$(ps -eo euser,comm 2>/dev/null | awk '$2~/^(gnome-session|ksmserver|xfce4-session|cinnamon-sessio|mate-session|startplasma-|wayland)/ {print $1; exit}')
    [[ -z "$user" ]] && user=$(who 2>/dev/null | awk '($2 ~ /:[0-9]/) {print $1; exit}')
    [[ -z "$user" ]] && user=$(getent passwd | awk -F: '$3 >= 1000 && $3 != 65534 {print $1}' | head -n 1)
    
    [[ -z "$user" ]] && return 1
    uid=$(id -u "$user" 2>/dev/null) || return 1
    dbus="unix:path=/run/user/$uid/bus"

    local d
    for d in :0 :1 :0.0 :1.0 ""; do
        if sudo -u "$user" DISPLAY="$d" DBUS_SESSION_BUS_ADDRESS="$dbus" \
           notify-send -a "Vacuum Optimizer" "$title" "$body" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

# -- Core Engine ---------------------------------------------------------------
V_AGG=false; V_QUIET=false; V_DRY=false
V_LOCK="/var/lock/vacuum.lock"

_cmd() { if ! $V_DRY; then eval "$@" >/dev/null 2>&1 || true; fi; }
_log() { printf "[%s][%s] %s\n" "$(date +"%F %T")" "$1" "$2" >> "$LOG_FILE" 2>/dev/null || true; }
_stats() { df / --output=pcent,avail -BM 2>/dev/null | tail -1 | tr -dc '0-9 ' | awk '{print ($1==""?0:$1)" "($2==""?0:$2)}'; }

_cleanup() {
    exec 200>"$V_LOCK"
    flock -n 200 || { _err "Vacuum is currently running in another process."; exit 1; }
    trap 'flock -u 200; rm -f "$V_LOCK"' EXIT

    mkdir -p "$REPORT_DIR"; touch "$LOG_FILE"; chmod 640 "$LOG_FILE"

    local pb am ts
    read -r pb am <<< "$(_stats)"; pb="${pb:-0}"; am="${am:-0}"
    ts=$(date +"%F %T")

    if [[ $pb -lt $THRESHOLD ]] && ! $V_AGG && ! $V_DRY; then
        $V_QUIET || _ok "Disk at ${pb}% (Below ${THRESHOLD}% threshold). Skipping."
        exit 0
    fi
    [[ $pb -ge $AGGRESSIVE_THRESHOLD ]] && V_AGG=true

    local mode="Standard"
    $V_AGG && mode="Aggressive"
    $V_DRY && mode="Simulation (Dry-Run)"
    
    _log INFO "Start | Mode: $mode | Disk: ${pb}%"

    $V_QUIET || { _hdr; _title "Executing Optimization"; _kv "Mode" "$mode"; _kv "Initial Load" "${pb}%"; echo; }

    # 1. System Logs
    $V_QUIET || _step "Vacuuming System Journals"
    _cmd "journalctl --vacuum-size='$JOURNAL_LIMIT'"
    _cmd "journalctl --vacuum-time='${JOURNAL_DAYS}d'"
    _cmd "find /var/log -type f -name '*.gz' -mtime +14 -o -name '*.log.*' -mtime +30 -delete"
    if command -v coredumpctl &>/dev/null; then _cmd "coredumpctl remove '> 7 days'"; fi
    $V_QUIET || _done

    # 2. Package Manager
    $V_QUIET || _step "Cleaning Package Manager"
    if command -v apt-get &>/dev/null; then
        _cmd "apt-get autoclean -y && apt-get autoremove --purge -y"
        if $V_AGG; then
            local old; old=$(dpkg -l 'linux-image-*' 2>/dev/null | awk '/^ii/{print $2}' | grep -v "$(uname -r)" | grep -v 'linux-image-generic' || true)
            [[ -n "$old" ]] && _cmd "apt-get remove --purge -y $old" || true
        fi
    elif command -v dnf &>/dev/null; then _cmd "dnf autoremove -y && dnf clean all"
    elif command -v pacman &>/dev/null; then
        _cmd "pacman -Sc --noconfirm"
        local orphans; orphans=$(pacman -Qdtq || true)
        [[ -n "$orphans" ]] && _cmd "pacman -Rns $orphans --noconfirm" || true
    fi
    $V_QUIET || _done

    # 3. Temp Files
    $V_QUIET || _step "Clearing System Temp Files"
    _cmd "find /tmp /var/tmp -mindepth 1 -not -name '.X*' -delete"
    _cmd "rm -rf /var/crash/*"
    $V_QUIET || _done

    # 4. User Profiles (Optimized Direct Paths)
    $V_QUIET || _step "Optimizing User Profiles"
    while IFS=: read -r u h; do
        [[ " $EXCLUDE_USERS " =~ " $u " ]] && continue
        [[ -d "$h" ]] || continue

        [[ -d "$h/.cache/thumbnails" ]] && _cmd "rm -rf '$h/.cache/thumbnails/'*"
        
        if [[ -d "$h/.cache" ]]; then
            if $V_AGG; then _cmd "find '$h/.cache' -mindepth 1 -delete"
            else _cmd "find '$h/.cache' -mindepth 1 -atime +${CACHE_AGE_DAYS} -delete"; fi
        fi
        
        [[ -d "$h/.local/share/Trash" ]] && _cmd "rm -rf '$h/.local/share/Trash/files/'* '$h/.local/share/Trash/info/'*"
        
        # Direct folder wipe is 100x faster than invoking npm/pip binaries
        [[ -d "$h/.npm/_cacache" ]] && _cmd "rm -rf '$h/.npm/_cacache'"
        [[ -d "$h/.cache/pip" ]] && _cmd "rm -rf '$h/.cache/pip'"
    done < <(getent passwd | awk -F: '$3 >= 1000 && $3 != 65534 {print $1 ":" $6}')
    $V_QUIET || _done

    # 5. Container & Snaps
    if command -v snap &>/dev/null; then
        $V_QUIET || _step "Pruning Snap Artifacts"
        _cmd "snap list --all 2>/dev/null | awk '/disabled/{print \$1, \$3}' | while read -r n r; do snap remove \"\$n\" --revision=\"\$r\"; done"
        $V_QUIET || _done
    fi

    if command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
        $V_QUIET || _step "Pruning Docker Engine"
        if $V_AGG; then _cmd "docker system prune -af --volumes"; else _cmd "docker system prune -f"; fi
        _cmd "docker builder prune -af"
        $V_QUIET || _done
    fi

    # Final Reporting
    local pa aa freed dur
    read -r pa aa <<< "$(_stats)"; pa="${pa:-0}"; aa="${aa:-0}"
    freed=$((aa - am)); [[ $freed -lt 0 ]] && freed=0
    dur=$(( $(date +%s) - $(date -d "$ts" +%s) ))
    $V_DRY && { pa=$pb; freed=0; }

    {
        printf "Vacuum Report -- %s\nMode: %s\nDisk: %s%% -> %s%%\nFreed: %s MB\nDuration: %ss\n" "$ts" "$mode" "$pb" "$pa" "$freed" "$dur"
    } > "$REPORT_DIR/$(date +%Y%m%d-%H%M%S).log" 2>/dev/null || true
    ls -t "$REPORT_DIR"/*.log 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null || true

    _log INFO "Done | ${pb}% -> ${pa}% | Freed: ${freed}MB | ${dur}s"

    $V_QUIET || {
        _title "Optimization Complete"
        _kv "Disk Before" "${pb}%"
        _kv "Disk After"  "${pa}%"
        _kv "Space Freed" "${c_grn}${c_bld}${freed} MB${c_rst}"
        _kv "Time Taken"  "${dur} seconds"
        echo
    }
}

# -- RAM Optimizer -------------------------------------------------------------
do_ram_optimizer() {
    _hdr; _title "Memory & Swap Optimizer"
    _warn "This will drop cached memory and reset swap space to free up RAM."
    _step "Syncing filesystem"
    sync; _done
    _step "Dropping pagecache, dentries, inodes"
    echo 3 > /proc/sys/vm/drop_caches; _done
    
    if [[ $(swapon --show 2>/dev/null | wc -l) -gt 0 ]]; then
        _step "Clearing Swap (May take a while)"
        swapoff -a && swapon -a; _done
    fi
    echo; _ok "Memory optimized successfully."
    sleep 3
}

# -- Background Auto-Monitor ---------------------------------------------------
do_monitor_daemon() {
    _log "MONITOR" "Service started. Checking every ${MONITOR_INTERVAL}s."
    while true; do
        local p load trigger_load
        read -r p _ <<< "$(_stats)"; p="${p:-0}"
        load=$(cat /proc/loadavg | awk '{print $1}')
        trigger_load=$(awk -v l="$load" -v t="$LOAD_THRESHOLD" 'BEGIN {if (l >= t) print 1; else print 0}')

        if [[ "$p" -ge "$THRESHOLD" ]] || [[ "$trigger_load" -eq 1 ]]; then
            _log "MONITOR" "Triggered! Disk: ${p}%, Load: ${load}"
            _notify "Auto-Monitor Triggered" "High usage detected (Disk: ${p}%, CPU: ${load}). Running background cleanup."
            
            if [[ "$p" -ge "$AGGRESSIVE_THRESHOLD" ]]; then
                V_AGG=true V_QUIET=true _cleanup
            else
                V_QUIET=true _cleanup
            fi
            
            _notify "Auto-Monitor Finished" "Background cleanup completed successfully."
            sleep 3600 # Sleep 1 hr after trigger
        else
            sleep "$MONITOR_INTERVAL"
        fi
    done
}

do_monitor_setup() {
    _hdr; _title "Auto-Monitor Setup"
    local self; self=$(realpath "$0")
    
    if systemctl is-active --quiet vacuum-monitor 2>/dev/null; then
        systemctl disable --now vacuum-monitor 2>/dev/null || true
        rm -f /etc/systemd/system/vacuum-monitor.service
        systemctl daemon-reload
        _ok "Auto-Monitor has been STOPPED and REMOVED."
    else
        cat > /etc/systemd/system/vacuum-monitor.service <<EOF
[Unit]
Description=Vacuum Auto-Monitor (Load & Disk Watchdog)
After=systemd-journald.socket
[Service]
Type=simple
ExecStart=$self --daemon
Restart=always
RestartSec=30
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now vacuum-monitor >/dev/null 2>&1
        _ok "Auto-Monitor has been STARTED."
        _kv "Disk Threshold" ">= ${THRESHOLD}%"
        _kv "Load Threshold" ">= ${LOAD_THRESHOLD}"
        _kv "Interval" "${MONITOR_INTERVAL} seconds"
        _kv "Notifications" "$NOTIFY"
    fi
    echo; read -rp "Press Enter to return..."
}

# -- Edit Limits & Settings ----------------------------------------------------
_update_conf() {
    local key="$1"
    local val="$2"
    local conf="/etc/vacuum.conf"
    
    [[ -f "$conf" ]] || touch "$conf"
    if grep -q "^${key}=" "$conf"; then
        sed -i "s/^${key}=.*/${key}=${val}/" "$conf"
    else
        echo "${key}=${val}" >> "$conf"
    fi
    eval "${key}=${val}"
    
    echo; _ok "Saved Settings -> [ ${c_bld}${key} = ${val}${c_rst} ]"
    sleep 1.5
}

_reset_conf() {
    cat > /etc/vacuum.conf <<EOF
THRESHOLD=$DEFAULT_THRESHOLD
AGGRESSIVE_THRESHOLD=$DEFAULT_AGGRESSIVE
LOAD_THRESHOLD=$DEFAULT_LOAD
MONITOR_INTERVAL=$DEFAULT_INTERVAL
NOTIFY=$DEFAULT_NOTIFY
EOF
    source /etc/vacuum.conf
    echo; _ok "All settings have been restored to factory defaults."
    sleep 2
}

do_edit_limits() {
    while true; do
        _hdr; _title "Configure Thresholds & Limits"
        _kv "1. Standard Disk Threshold" "${THRESHOLD}%"
        _kv "2. Aggressive Disk Threshold" "${AGGRESSIVE_THRESHOLD}%"
        _kv "3. High CPU Load Threshold" "${LOAD_THRESHOLD}"
        _kv "4. Monitor Check Interval" "${MONITOR_INTERVAL} sec"
        _kv "5. Desktop Notifications" "${NOTIFY}"
        _kv "6. Test Desktop Notification" "Send a test pop-up now"
        _kv "7. Factory Reset Settings" "Restore default limits"
        printf "  [0] Back to Main Menu\n\n"
        
        read -rp "  [>>] Enter setting to edit (0-7): " opt
        case "$opt" in
            1) 
                read -rp "  [>>] Enter New Disk Threshold (1-99): " val
                if [[ "$val" =~ ^[0-9]+$ ]]; then _update_conf "THRESHOLD" "$val"; else _err "Invalid number."; sleep 1; fi ;;
            2) 
                read -rp "  [>>] Enter New Aggressive Threshold (1-99): " val
                if [[ "$val" =~ ^[0-9]+$ ]]; then _update_conf "AGGRESSIVE_THRESHOLD" "$val"; else _err "Invalid number."; sleep 1; fi ;;
            3) 
                read -rp "  [>>] Enter New CPU Load Threshold (e.g., 4.0): " val
                _update_conf "LOAD_THRESHOLD" "$val" ;;
            4) 
                read -rp "  [>>] Enter New Check Interval in sec (e.g., 60): " val
                if [[ "$val" =~ ^[0-9]+$ ]]; then _update_conf "MONITOR_INTERVAL" "$val"; else _err "Invalid number."; sleep 1; fi ;;
            5) 
                read -rp "  [>>] Enable Desktop Notifications? (true/false): " val
                if [[ "$val" == "true" || "$val" == "false" ]]; then _update_conf "NOTIFY" "$val"; else _err "Must type true or false."; sleep 1; fi ;;
            6)
                echo
                _step "Sending test notification"
                if _notify "Vacuum Setup" "Notifications are working successfully!"; then _done
                else _err "Failed. Ensure your desktop supports 'notify-send'."; sleep 2; fi
                sleep 1 ;;
            7)
                _reset_conf ;;
            0) 
                if systemctl is-active --quiet vacuum-monitor 2>/dev/null; then
                    echo; _step "Restarting Auto-Monitor to apply new limits"
                    systemctl restart vacuum-monitor 2>/dev/null || true
                    _done
                    sleep 1
                fi
                return ;;
            *) 
                _err "Invalid selection."
                sleep 1 ;;
        esac
    done
}

# -- Scheduler & Menus ---------------------------------------------------------
do_schedule_menu() {
    _hdr; _title "Time-Based Scheduler"
    
    if systemctl is-active --quiet vacuum.timer 2>/dev/null; then
        local nr curr_sch
        nr=$(systemctl list-timers vacuum.timer --no-pager 2>/dev/null | awk 'NR==2 {print $1" "$2}' || true)
        curr_sch=$(grep "OnCalendar=" /etc/systemd/system/vacuum.timer 2>/dev/null | cut -d'=' -f2 || true)
        [[ -z "$curr_sch" ]] && curr_sch="Unknown"
        
        _warn "Scheduler is currently ACTIVE."
        _kv "Current Schedule" "$curr_sch"
        _kv "Next Run" "${nr:-Unknown}"
        echo
    else
        _kv "Current Schedule" "Disabled"
        echo
    fi

    printf "  [1] Every 30 Minutes\n"
    printf "  [2] Every 1 Hour\n"
    printf "  [3] Daily at Midnight\n"
    printf "  [4] Weekly (Sunday 3:00 AM)\n"
    printf "  [5] Custom Cron String\n"
    printf "  [6] Remove & Disable Scheduler\n"
    printf "  [0] Back to Main Menu\n\n"
    
    read -rp "  [>>] Select an option: " opt
    echo

    if [[ "$opt" == "6" ]]; then
        systemctl disable --now vacuum.timer 2>/dev/null || true
        rm -f /etc/systemd/system/vacuum.{service,timer}
        systemctl daemon-reload
        _ok "Scheduler completely removed."
        sleep 2; return
    elif [[ "$opt" == "0" || -z "$opt" ]]; then
        return
    fi

    local cal="daily"
    case "$opt" in
        1) cal="*:0/30" ;;
        2) cal="hourly" ;;
        3) cal="daily" ;;
        4) cal="Sun *-*-* 03:00:00" ;;
        5) read -rp "  [>>] Enter systemd OnCalendar string (e.g., '*-*-* 04:00:00'): " cal ;;
    esac

    local self; self=$(realpath "$0")
    cat > /etc/systemd/system/vacuum.service <<EOF
[Unit]
Description=Vacuum Disk Cleanup
[Service]
Type=oneshot
ExecStart=$self -r -q
EOF
    cat > /etc/systemd/system/vacuum.timer <<EOF
[Unit]
Description=Vacuum Timer
Requires=vacuum.service
[Timer]
OnCalendar=$cal
Persistent=true
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now vacuum.timer >/dev/null 2>&1
    _ok "Scheduler enabled for: $cal"
    sleep 2
}

do_status() {
    _hdr; _title "System Dashboard"
    local p _; read -r p _ <<< "$(_stats)"; p="${p:-0}"
    
    printf "  %-30s : " "Disk Usage"; _bar "$p"; echo
    
    local mem_raw mem_pct
    mem_raw=$(free -m 2>/dev/null | awk '/^Mem:/{print $3/$2 * 100.0}' || echo "0")
    mem_pct=$(printf "%.0f" "$mem_raw")
    printf "  %-30s : " "Memory"; _bar "$mem_pct"; echo; echo

    _kv "Load Avg" "$(cat /proc/loadavg | awk '{print $1" "$2" "$3}')"
    _kv "Uptime" "$(uptime -p 2>/dev/null | sed 's/up //' || true)"
    
    _title "Background Services"
    if systemctl is-active --quiet vacuum.timer 2>/dev/null; then
        local next_run
        next_run=$(systemctl list-timers vacuum.timer --no-pager 2>/dev/null | awk 'NR==2 {print $1" "$2}' || true)
        _kv "Timer Scheduler" "Active (Next run: ${next_run:-Unknown})"
    else
        _kv "Timer Scheduler" "Inactive"
    fi

    if systemctl is-active --quiet vacuum-monitor 2>/dev/null; then
        _kv "Auto-Monitor Watchdog" "Active"
        _kv "-> Monitors Disk Usage >=" "${THRESHOLD}%"
        _kv "-> Monitors CPU Load >=" "${LOAD_THRESHOLD}"
    else
        _kv "Auto-Monitor Watchdog" "Inactive"
    fi
    echo
}

do_interactive() {
    while true; do
        _hdr; _title "Main Menu"
        printf "  [1] Standard Cleanup\n"
        printf "  [2] Aggressive Cleanup (Deep Clean)\n"
        printf "  [3] Simulate Cleanup (Dry-Run)\n"
        printf "  [4] Optimize RAM & Clear Swap\n"
        printf "  [5] System Dashboard\n"
        printf "  [6] Configure Limits & Settings\n"
        printf "  [7] Manage Time-Based Scheduler\n"
        printf "  [8] Toggle Auto-Monitor (Load/Hang Watchdog)\n"
        printf "  [0] Exit\n\n"
        
        read -rp "  [>>] Select an option: " opt
        
        case "$opt" in
            1) _root; _cleanup; read -rp "Press Enter to continue..." ;;
            2) _root; V_AGG=true; _cleanup; read -rp "Press Enter to continue..." ;;
            3) _root; V_DRY=true; _cleanup; read -rp "Press Enter to continue..." ;;
            4) _root; do_ram_optimizer ;;
            5) do_status; read -rp "Press Enter to continue..." ;;
            6) _root; do_edit_limits ;;
            7) _root; do_schedule_menu ;;
            8) _root; do_monitor_setup ;;
            0) echo; exit 0 ;;
            *) echo ;;
        esac
    done
}

do_help() {
    _hdr; _title "Command Line Usage"
    printf "  sudo vacuum [FLAGS]\n\n"
    _kv "-i, --interactive" "Launch Interactive Menu"
    _kv "-r, --run"         "Execute standard cleanup"
    _kv "-a, --aggressive"  "Deep clean (Docker volumes, Kernels, All caches)"
    _kv "-d, --dry-run"     "Simulate cleanup without deleting"
    _kv "-q, --quiet"       "Suppress UI (For cron/systemd)"
    _kv "-s, --status"      "View Dashboard & Scheduler Status"
    _kv "-S, --schedule"    "Launch Scheduler Manager directly"
    _kv "-M, --monitor"     "Toggle Background Auto-Monitor"
    _kv "-I, --install"     "Install auto-completion & config"
    _kv "-h, --help"        "Show this help page (Default)"
    echo
}

do_install() {
    _hdr; _root; _title "Installation"
    mkdir -p "$REPORT_DIR" /etc/bash_completion.d; touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"; chmod 750 "$REPORT_DIR"
    
    cat > /etc/bash_completion.d/vacuum <<'EOF'
complete -W "-i --interactive -r --run -a --aggressive -d --dry-run -q --quiet -s --status -S --schedule -M --monitor -h --help" vacuum
EOF
    if [[ ! -f /etc/vacuum.conf ]]; then
        cat > /etc/vacuum.conf <<EOF
THRESHOLD=$THRESHOLD
AGGRESSIVE_THRESHOLD=$AGGRESSIVE_THRESHOLD
LOAD_THRESHOLD=$LOAD_THRESHOLD
MONITOR_INTERVAL=$MONITOR_INTERVAL
NOTIFY=$NOTIFY
EOF
    fi
    _ok "Directories configured"
    _ok "Config generated at /etc/vacuum.conf"
    _ok "Bash auto-completion installed"
    echo; _ok "Vacuum installed successfully!"; echo
}

# -- Router --------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
    do_help
    exit 0
fi

ACTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--interactive) ACTION="interactive" ;;
        -r|--run)         ACTION="run" ;;
        -a|--aggressive)  ACTION="agg" ;;
        -d|--dry-run)     V_DRY=true; ACTION="${ACTION:-run}" ;;
        -q|--quiet)       V_QUIET=true ;;
        -S|--schedule)    ACTION="schedule" ;;
        -M|--monitor)     ACTION="monitor_setup" ;;
        --daemon)         ACTION="daemon" ;;
        -s|--status)      ACTION="status" ;;
        -I|--install)     ACTION="install" ;;
        -h|--help)        ACTION="help" ;;
        -*)               _err "Unknown flag: $1"; do_help; exit 1 ;;
    esac
    shift
done

[[ -n "$V_QUIET" && -z "$ACTION" ]] && ACTION="run"

case "$ACTION" in
    interactive)   do_interactive ;;
    run)           _root; _cleanup ;;
    agg)           _root; V_AGG=true; _cleanup ;;
    schedule)      _root; do_schedule_menu ;;
    monitor_setup) _root; do_monitor_setup ;;
    daemon)        _root; do_monitor_daemon ;;
    status)        do_status ;;
    install)       do_install ;;
    help)          do_help ;;
esac
