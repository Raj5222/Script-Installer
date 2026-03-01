#!/usr/bin/env bash
# =============================================================================
# VACUUM -- Advanced Optimizer with Interactive Deletion Safeguards
# =============================================================================
set -euo pipefail

# =============================================================================
#  SECTION A -- DEFAULTS & CONFIGURATION
# =============================================================================
DEFAULT_THRESHOLD=85
DEFAULT_AGGRESSIVE=95
DEFAULT_LOAD=4.0
DEFAULT_INTERVAL=60
DEFAULT_NOTIFY=true

DEFAULT_SAFE_RAM_PCT=75
DEFAULT_JOURNAL_LIMIT="100M"
DEFAULT_JOURNAL_DAYS=14
DEFAULT_CACHE_AGE_DAYS=30
DEFAULT_DEV_CACHE_DAYS=30
DEFAULT_EXCLUDE_USERS="root"
DEFAULT_EXCLUDE_PATHS="" 

DEFAULT_SWAPPINESS=10
DEFAULT_VFS_CACHE_PRESSURE=50
DEFAULT_DIRTY_RATIO=10
DEFAULT_DIRTY_BG_RATIO=5

DEFAULT_REAPER_ENABLED=false
DEFAULT_REAPER_THRESHOLD=20 

THRESHOLD=$DEFAULT_THRESHOLD
AGGRESSIVE_THRESHOLD=$DEFAULT_AGGRESSIVE
LOAD_THRESHOLD=$DEFAULT_LOAD
MONITOR_INTERVAL=$DEFAULT_INTERVAL
NOTIFY=$DEFAULT_NOTIFY
SAFE_RAM_PCT=$DEFAULT_SAFE_RAM_PCT
JOURNAL_LIMIT=$DEFAULT_JOURNAL_LIMIT
JOURNAL_DAYS=$DEFAULT_JOURNAL_DAYS
CACHE_AGE_DAYS=$DEFAULT_CACHE_AGE_DAYS
DEV_CACHE_DAYS=$DEFAULT_DEV_CACHE_DAYS
EXCLUDE_USERS=$DEFAULT_EXCLUDE_USERS
EXCLUDE_PATHS=$DEFAULT_EXCLUDE_PATHS
SWAPPINESS=$DEFAULT_SWAPPINESS
VFS_CACHE_PRESSURE=$DEFAULT_VFS_CACHE_PRESSURE
DIRTY_RATIO=$DEFAULT_DIRTY_RATIO
DIRTY_BG_RATIO=$DEFAULT_DIRTY_BG_RATIO
REAPER_ENABLED=$DEFAULT_REAPER_ENABLED
REAPER_THRESHOLD=$DEFAULT_REAPER_THRESHOLD

LOG_FILE="/var/log/vacuum.log"
REPORT_DIR="/var/log/vacuum-reports"

[[ -f /etc/vacuum.conf ]] && source /etc/vacuum.conf || true

V_AGG=false; V_DEV=false; V_PERF=false; V_QUIET=false; V_DRY=false; V_MONITOR_MODE=false; V_AUTO_YES=false

# =============================================================================
#  SECTION B -- UI ENGINE
# =============================================================================
if [[ -t 1 ]] && tput colors &>/dev/null 2>&1; then
    C_RST=$'\e[0m';  C_BLD=$'\e[1m';  C_DIM=$'\e[2m'
    C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLU=$'\e[34m'
    C_MAG=$'\e[35m'; C_CYN=$'\e[36m'; C_WHT=$'\e[97m'; C_GRY=$'\e[90m'; C_PRP=$'\e[38;5;135m'
else
    C_RST=''; C_BLD=''; C_DIM=''; C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_MAG=''; C_CYN=''; C_WHT=''; C_GRY=''; C_PRP=''
fi

_tw()   { tput cols 2>/dev/null || echo 80; }
_line() { printf "${C_DIM}%*s${C_RST}\e[K\n" "$(_tw)" '' | tr ' ' '-'; }
_blank(){ printf "\e[K\n"; }

_hdr() {
    clear; _blank
    printf "${C_CYN}${C_BLD}  [⚙] VACUUM ${C_RST}${C_CYN}-- System Optimizer${C_RST}\e[K\n"
    _line; _blank
}

_section() { _blank; printf "  ${C_BLD}${C_WHT}■ %s${C_RST}\e[K\n" "$1"; _line; }
_step()    { printf "  ${C_BLU}❯${C_RST} %-52s" "$1..."; }
_done()    { printf "[ ${C_GRN}OK${C_RST} ]\e[K\n"; }
_skip()    { printf "[ ${C_GRY}SKIP${C_RST} ]\e[K\n"; }
_ok()      { printf "  ${C_GRN}✓${C_RST} %s\e[K\n" "$1"; }
_err()     { printf "  ${C_RED}✗ FAIL:${C_RST} %s\e[K\n" "$1" >&2; }
_warn()    { printf "  ${C_YLW}⚠ WARN:${C_RST} %s\e[K\n" "$1"; }
_info()    { printf "  ${C_CYN}ℹ INFO:${C_RST} %s\e[K\n" "$1"; }
_kv()      { printf "    ${C_GRY}%-32s${C_RST} %s\e[K\n" "$1" "$2"; }

_rich_bar() {
    local pct="${1:-0}" title="$2" detail="$3" w=26 f e c
    f=$(( pct * w / 100 )); [[ $f -gt $w ]] && f=$w
    e=$(( w - f )); [[ $e -lt 0 ]] && e=0
    c="$C_GRN"; [[ $pct -ge 75 ]] && c="$C_YLW"; [[ $pct -ge 90 ]] && c="$C_RED"
    printf "  ${C_BLD}%-7s${C_RST} ${c}[%s%s] %3d%%${C_RST}   ${C_WHT}%s${C_RST}\e[K\n" "$title" "$(printf '%*s' "$f" '' | tr ' ' '█')" "$(printf '%*s' "$e" '' | tr ' ' '░')" "$pct" "$detail"
}

_root() { [[ $EUID -eq 0 ]] || { _err "Root privileges required. Run with sudo."; exit 1; }; }
_log()  { printf "[%s][%s] %s\n" "$(date +"%F %T")" "$1" "$2" >> "$LOG_FILE" 2>/dev/null || true; }

_ask_confirm() {
    local target="$1" size="$2"
    if $V_QUIET || $V_AUTO_YES; then return 0; fi
    printf "    ${C_YLW}? Remove %s [%s]? (y/N): ${C_RST}" "$target" "$size"
    local ans=""
    read -r ans </dev/tty || true
    if [[ "$ans" =~ ^[Yy]$ ]]; then return 0; else return 1; fi
}

# =============================================================================
#  SECTION C -- SYSTEM METRICS PARSERS
# =============================================================================
_disk_p() { df / --output=pcent 2>/dev/null | tail -1 | tr -dc '0-9'; }
_disk_avail_mb() { df / --output=avail -BM 2>/dev/null | tail -1 | tr -dc '0-9'; }
_ram_p()  { free 2>/dev/null | awk '/^Mem:/ { if ($2>0) printf "%d", $3*100/$2; else print 0 }'; }
_swap_p() { free 2>/dev/null | awk '/^Swap:/ { if ($2>0) printf "%d", $3*100/$2; else print 0 }'; }

# =============================================================================
#  SECTION D -- SUBSYSTEMS & REAPER
# =============================================================================
_reap_processes() {
    $V_QUIET || _step "Scanning for memory hogs (> ${REAPER_THRESHOLD}%)"
    if [[ "${REAPER_ENABLED}" != "true" ]]; then $V_QUIET || _skip; return; fi

    local sys_ram killed_any=false; sys_ram=$(_ram_p)
    if [[ "$sys_ram" -lt 85 && "$V_AGG" == "false" && "$V_PERF" == "false" ]]; then
        $V_QUIET || _skip; return
    fi

    while read -r pid comm mem; do
        if [[ "$comm" =~ ^(systemd|Xorg|wayland|gnome-shell|kwin|plasma|vacuum|sshd|dbus-daemon)$ ]]; then continue; fi
        local over_limit; over_limit=$(awk -v m="$mem" -v t="$REAPER_THRESHOLD" 'BEGIN { print (m > t) ? 1 : 0 }')
        
        if [[ "$over_limit" -eq 1 ]]; then
            $V_QUIET || printf "\n  ${C_RED}↳ KILLED:${C_RST} %s (PID: %s) using %s%% RAM" "$comm" "$pid" "$mem"
            _log "REAPER" "Terminated $comm (PID: $pid) for using $mem% RAM."
            kill -15 "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
            killed_any=true
        fi
    done < <(ps -eo pid,comm,%mem --sort=-%mem | awk 'NR>1 {print $1, $2, $3}' | head -n 10)

    if $killed_any; then $V_QUIET || printf "\n"; else $V_QUIET || _done; fi
}

_dev_cleanup() {
    $V_QUIET || _section "Developer & Database Artifact Cleanup"
    
    local find_excludes=()
    if [[ -n "${EXCLUDE_PATHS:-}" ]]; then
        for excl in $EXCLUDE_PATHS; do
            if [[ "$excl" == /* ]]; then find_excludes+=( "-path" "$excl" "-prune" "-o" )
            else find_excludes+=( "-name" "$excl" "-prune" "-o" ); fi
        done
    fi
    
    $V_QUIET || _step "Purging NPM, Yarn, pnpm, and Bun caches"
    $V_QUIET || _done
    local h u
    while IFS=: read -r u h; do
        [[ " $EXCLUDE_USERS " =~ " $u " ]] && continue || true
        local dev_caches=("$h/.npm/_cacache" "$h/.cache/yarn" "$h/.local/share/pnpm/store" "$h/.bun/install/cache" "$h/.cache/go-build" "$h/.cargo/registry/cache")
        for dc in "${dev_caches[@]}"; do
            if [[ -d "$dc" ]]; then
                local sz=$(du -sh "$dc" 2>/dev/null | cut -f1 || echo "?")
                if _ask_confirm "$dc" "$sz"; then
                    $V_QUIET || printf "    ${C_GRY}↳ Cleared: %s [%s]${C_RST}\n" "$dc" "$sz"
                    rm -rf "$dc" 2>/dev/null || true
                else
                    $V_QUIET || printf "    ${C_GRY}↳ Skipped: %s${C_RST}\n" "$dc"
                fi
            fi
        done
    done < <(getent passwd 2>/dev/null | awk -F: '$3>=1000 && $3!=65534 { print $1":"$6 }')

    local msg_str="(All)"
    if [[ "$DEV_CACHE_DAYS" -gt 0 ]]; then msg_str="(> ${DEV_CACHE_DAYS} days)"; fi
    $V_QUIET || _step "Scanning for node_modules ${msg_str}"
    
    local stale_nodes=""
    if [[ "$DEV_CACHE_DAYS" -eq 0 ]]; then
        # 0 days = find all immediately
        stale_nodes=$(find /home ${find_excludes[@]+"${find_excludes[@]}"} -type d -name "node_modules" -prune -print 2>/dev/null || true)
    else
        # Match age
        stale_nodes=$(find /home ${find_excludes[@]+"${find_excludes[@]}"} -type d -name "node_modules" -mtime +"${DEV_CACHE_DAYS}" -prune -print 2>/dev/null || true)
    fi
    
    if [[ -n "$stale_nodes" ]]; then
        $V_QUIET || _done
        while IFS= read -r nd; do
            [[ -z "$nd" ]] && continue
            local sz=$(du -sh "$nd" 2>/dev/null | cut -f1 || echo "?")
            if _ask_confirm "$nd" "$sz"; then
                $V_QUIET || printf "    ${C_RED}↳ Nuked:${C_RST} %s ${C_GRY}[%s]${C_RST}\n" "$nd" "$sz"
                rm -rf "$nd" 2>/dev/null || true
            else
                $V_QUIET || printf "    ${C_GRY}↳ Skipped: %s${C_RST}\n" "$nd"
            fi
        done <<< "$stale_nodes"
    else
        $V_QUIET || _skip
        $V_QUIET || printf "    ${C_GRY}↳ No node_modules found matching criteria.${C_RST}\n"
    fi

    $V_QUIET || _step "Clearing PostgreSQL/MongoDB temp sockets & logs"
    local pg_socks=$(find /tmp -name ".s.PGSQL.*" -mtime +2 2>/dev/null || true)
    local mg_socks=$(find /tmp -name "mongodb-*.sock" -mtime +2 2>/dev/null || true)
    $V_QUIET || _done
    for sock in $pg_socks $mg_socks; do
        [[ -z "$sock" ]] && continue
        $V_QUIET || printf "    ${C_GRY}↳ Removed socket: %s${C_RST}\n" "$sock"
        rm -f "$sock" 2>/dev/null || true
    done
    
    $V_QUIET || _step "Pruning dangling Docker images & builder caches"
    if command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
        local d_out=""
        if $V_AGG; then d_out=$(docker system prune -af --volumes 2>/dev/null | grep -i "Total reclaimed space" || true)
        else d_out=$(docker system prune -f 2>/dev/null | grep -i "Total reclaimed space" || true); fi
        $V_QUIET || _done
        [[ -n "$d_out" ]] && { $V_QUIET || printf "    ${C_GRY}↳ Docker %s${C_RST}\n" "$d_out"; }
    else
        $V_QUIET || _skip
    fi
}

_do_memory_cleanup() {
    local rp st
    rp=$(_ram_p); st=$(free -m | awk '/^Swap:/ {print $2}')

    _reap_processes

    $V_QUIET || _step "Synchronising dirty buffers to disk"; sync; sync; $V_QUIET || _done
    $V_QUIET || _step "Releasing level 1, 2 & 3 caches"; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true; $V_QUIET || _done
    $V_QUIET || _step "Compacting kernel memory footprint"; [[ -f /proc/sys/vm/compact_memory ]] && echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true; $V_QUIET || _done

    if $V_PERF; then
        $V_QUIET || _step "Setting Maximum Performance CPU Governor"
        echo "performance" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 || true
        $V_QUIET || _done
        $V_QUIET || _step "Enforcing absolute RAM usage (Swappiness=1)"
        sysctl -w vm.swappiness=1 >/dev/null 2>&1 || true; sysctl -w vm.vfs_cache_pressure=100 >/dev/null 2>&1 || true
        $V_QUIET || _done
    else
        $V_QUIET || _step "Applying sysctl memory tuning parameters"
        sysctl -w vm.swappiness="${SWAPPINESS}" >/dev/null 2>&1 || true; sysctl -w vm.vfs_cache_pressure="${VFS_CACHE_PRESSURE}" >/dev/null 2>&1 || true
        sysctl -w vm.dirty_ratio="${DIRTY_RATIO}" >/dev/null 2>&1 || true; sysctl -w vm.dirty_background_ratio="${DIRTY_BG_RATIO}" >/dev/null 2>&1 || true
        $V_QUIET || _done
    fi

    if [[ ${st:-0} -gt 0 ]]; then
        if [[ ${rp:-0} -lt ${SAFE_RAM_PCT:-75} || "$V_PERF" == "true" ]]; then
            $V_QUIET || _step "Flushing swap space to force processes to RAM"; swapoff -a 2>/dev/null && swapon -a 2>/dev/null || true; $V_QUIET || _done
        else
            $V_QUIET || _step "Swap flush deferred (RAM ${rp}% > Limit ${SAFE_RAM_PCT}%)"; $V_QUIET || _skip
        fi
    fi
}

_cleanup() {
    mkdir -p "$REPORT_DIR"; touch "$LOG_FILE"; chmod 640 "$LOG_FILE"
    local d_before d_after mb_before mb_after ts dur freed r_before r_after
    d_before=$(_disk_p); mb_before=$(_disk_avail_mb); r_before=$(_ram_p); ts=$(date +%s)

    local find_excludes=()
    if [[ -n "${EXCLUDE_PATHS:-}" ]]; then
        for excl in $EXCLUDE_PATHS; do
            if [[ "$excl" == /* ]]; then find_excludes+=( "-path" "$excl" "-prune" "-o" )
            else find_excludes+=( "-name" "$excl" "-prune" "-o" ); fi
        done
    fi

    if $V_MONITOR_MODE && [[ ${d_before:-0} -lt ${THRESHOLD:-85} ]] && ! $V_AGG && ! $V_DEV && ! $V_PERF; then return 0; fi
    [[ ${d_before:-0} -ge ${AGGRESSIVE_THRESHOLD:-95} ]] && V_AGG=true || true

    local mode="Standard"
    $V_AGG && mode="Aggressive"; $V_DEV && mode="Developer"; $V_PERF && mode="Performance Boost"
    _log INFO "Start | Mode: $mode | Disk: ${d_before}%"

    $V_QUIET || { _hdr; _section "System Optimizer Execution"; _kv "Profile Active" "${C_PRP}${mode}${C_RST}"; _blank; }

    $V_QUIET || _step "Vacuuming systemd journals"
    journalctl --vacuum-size="$JOURNAL_LIMIT" >/dev/null 2>&1 || true; journalctl --vacuum-time="${JOURNAL_DAYS}d" >/dev/null 2>&1 || true; $V_QUIET || _done

    $V_QUIET || _step "Clearing package manager caches & orphans"
    if command -v apt-get &>/dev/null; then 
        local apt_sz=$(du -sh /var/cache/apt/archives 2>/dev/null | cut -f1 || echo "?")
        if _ask_confirm "/var/cache/apt/archives" "$apt_sz"; then
            apt-get autoclean -y >/dev/null 2>&1 || true; apt-get autoremove --purge -y >/dev/null 2>&1 || true; apt-get clean >/dev/null 2>&1 || true
            $V_AGG && rm -rf /var/cache/apt/archives/*.deb 2>/dev/null || true
            $V_QUIET || _done
            [[ "$V_AGG" == "true" || "$V_DEV" == "true" ]] && { $V_QUIET || printf "    ${C_GRY}↳ APT Cache Purged [%s]${C_RST}\n" "$apt_sz"; }
        else
            $V_QUIET || _skip
        fi
    elif command -v dnf &>/dev/null; then 
        dnf autoremove -y >/dev/null 2>&1 || true; dnf clean all >/dev/null 2>&1 || true; $V_QUIET || _done
    else
        $V_QUIET || _skip
    fi

    $V_QUIET || _step "Clearing /tmp and stale session remnants"
    find /tmp /var/tmp -mindepth 1 ${find_excludes[@]+"${find_excludes[@]}"} \( -name '.X*' -o -name '.ICE*' \) -prune -o -exec rm -rf '{}' + 2>/dev/null || true; $V_QUIET || _done

    $V_QUIET || _step "Clearing general application caches & trash"
    $V_QUIET || _done
    local u h
    while IFS=: read -r u h; do
        [[ " $EXCLUDE_USERS " =~ " $u " ]] && continue || true; [[ -d "$h" ]] || continue
        
        local c_dir="$h/.cache"; local t_dir="$h/.local/share/Trash"
        if [[ -d "$c_dir" ]]; then
            local c_sz=$(du -sh "$c_dir" 2>/dev/null | cut -f1 || echo "?")
            if _ask_confirm "$c_dir" "$c_sz"; then
                if $V_AGG || [[ "$CACHE_AGE_DAYS" -eq 0 ]]; then 
                    find "$c_dir" -mindepth 1 ${find_excludes[@]+"${find_excludes[@]}"} -exec rm -rf '{}' + 2>/dev/null || true
                else 
                    find "$c_dir" -mindepth 1 ${find_excludes[@]+"${find_excludes[@]}"} -atime "+${CACHE_AGE_DAYS}" -exec rm -rf '{}' + 2>/dev/null || true
                fi
                $V_QUIET || printf "    ${C_GRY}↳ Cleared Cache: %s [%s]${C_RST}\n" "$c_dir" "$c_sz"
            else
                $V_QUIET || printf "    ${C_GRY}↳ Skipped Cache: %s${C_RST}\n" "$c_dir"
            fi
        fi
        
        if $V_AGG && [[ -d "$t_dir" ]]; then
            local t_sz=$(du -sh "$t_dir" 2>/dev/null | cut -f1 || echo "?")
            if _ask_confirm "$t_dir" "$t_sz"; then
                rm -rf "$t_dir/files/"* "$t_dir/info/"* 2>/dev/null || true
                $V_QUIET || printf "    ${C_GRY}↳ Emptied Trash: %s [%s]${C_RST}\n" "$t_dir" "$t_sz"
            else
                $V_QUIET || printf "    ${C_GRY}↳ Skipped Trash: %s${C_RST}\n" "$t_dir"
            fi
        fi
    done < <(getent passwd 2>/dev/null | awk -F: '$3>=1000 && $3!=65534 { print $1":"$6 }')

    $V_QUIET || _step "Issuing TRIM to SSD storage volumes"
    command -v fstrim &>/dev/null && fstrim -av >/dev/null 2>&1 || true; $V_QUIET || _done

    if $V_DEV || $V_AGG; then _dev_cleanup; fi

    $V_QUIET || _section "Memory Reclamation Subsystem"
    _do_memory_cleanup

    d_after=$(_disk_p); mb_after=$(_disk_avail_mb); r_after=$(_ram_p)
    freed=$(( mb_after - mb_before )); [[ $freed -lt 0 ]] && freed=0; dur=$(( $(date +%s) - ts ))

    _log INFO "Done | Disk: ${d_before}% -> ${d_after}% | Freed: ${freed}MB"
    $V_QUIET || { _section "Execution Summary"; _kv "Space Reclaimed" "${C_GRN}${C_BLD}${freed} MB${C_RST}"; _blank; _ok "Vacuum execution completed."; _blank; }
}

# =============================================================================
#  SECTION E -- LIVE FLICKER-FREE DASHBOARD
# =============================================================================
do_dashboard() {
    _root
    printf "\e[?25l" # Hide cursor
    clear
    trap 'printf "\e[?25h\n"; exit 0' INT TERM QUIT

    while true; do
        printf "\e[H" # Move cursor to home
        
        printf "${C_CYN}${C_BLD}  [⚙] VACUUM ${C_RST}${C_CYN}-- Live Telemetry & Resource Dashboard${C_RST}\e[K\n"
        _line; _blank

        local c_usr c_sys c_idl cpu_pct load cores
        read -r c_usr c_sys c_idl <<< $(LC_ALL=C top -bn1 | grep -i '%Cpu' | tr ',' '.' | awk '{print $2, $4, $8}' | tr -d '%id,us,sy')
        cpu_pct=$(awk -v idl="${c_idl:-100}" 'BEGIN { printf "%d", 100 - idl }' 2>/dev/null || echo 0)
        load=$(awk '{print $1, $2, $3}' /proc/loadavg); cores=$(nproc 2>/dev/null || echo 1)

        local r_tot r_use r_buf r_fre r_pct s_tot s_use s_fre s_pct
        read -r r_tot r_use r_fre r_buf <<< $(free -m | awk '/^Mem:/ {print $2, $3, $4, $6}')
        r_pct=0; [[ $r_tot -gt 0 ]] && r_pct=$(( r_use * 100 / r_tot ))
        read -r s_tot s_use s_fre <<< $(free -m | awk '/^Swap:/ {print $2, $3, $4}')
        s_pct=0; [[ $s_tot -gt 0 ]] && s_pct=$(( s_use * 100 / s_tot ))

        local d_pct d_use d_tot
        read -r d_pct d_use d_tot <<< $(df -h / | awk 'NR==2 {print $5, $3, $2}' | tr -d '%')

        printf "  ${C_WHT}${C_BLD}HARDWARE METRICS${C_RST}\e[K\n"
        _rich_bar "$cpu_pct"      "CPU"  "Load: $load | Cores: $cores | Usr: ${c_usr}% Sys: ${c_sys}%"
        _rich_bar "$r_pct"        "RAM"  "Used: ${r_use}MB / ${r_tot}MB | Cache: ${r_buf}MB | Free: ${r_fre}MB"
        _rich_bar "$s_pct"        "SWAP" "Used: ${s_use:-0}MB / ${s_tot:-0}MB | Free: ${s_fre:-0}MB"
        _rich_bar "${d_pct:-0}"   "DISK" "Used: ${d_use:-0} / ${d_tot:-0} | Root Partition ( / )"
        
        _blank; _line; _blank
        
        printf "  ${C_WHT}${C_BLD}TOP RAM CONSUMERS${C_RST}                                 ${C_WHT}${C_BLD}TOP CPU CONSUMERS${C_RST}\e[K\n"
        printf "  ${C_GRY}%-7s %-18s %-9s${C_RST} ${C_DIM}|${C_RST} ${C_GRY}%-7s %-18s %-9s${C_RST}\e[K\n" "PID" "PROCESS" "MEM%" "PID" "PROCESS" "CPU%"

        local rpids=() rcomms=() rpcts=() cpids=() ccomms=() cpcts=()
        while read -r p c m; do rpids+=("$p"); rcomms+=("$c"); rpcts+=("$m"); done < <(ps -eo pid,comm,%mem --sort=-%mem | awk 'NR>1 {print $1, substr($2,1,18), $3}' | head -n 5)
        while read -r p c m; do cpids+=("$p"); ccomms+=("$c"); cpcts+=("$m"); done < <(ps -eo pid,comm,%cpu --sort=-%cpu | awk 'NR>1 {print $1, substr($2,1,18), $3}' | head -n 5)

        for i in {0..4}; do
            printf "  %-7s %-18s %-9s ${C_DIM}|${C_RST} %-7s %-18s %-9s\e[K\n" \
                "${rpids[i]:--}" "${rcomms[i]:--}" "${rpcts[i]:--}%" \
                "${cpids[i]:--}" "${ccomms[i]:--}" "${cpcts[i]:--}%"
        done

        _blank; _line; _blank

        printf "  ${C_WHT}${C_BLD}TOP SWAP CONSUMERS${C_RST}                                ${C_WHT}${C_BLD}TOP DISK PARTITIONS${C_RST}\e[K\n"
        printf "  ${C_GRY}%-7s %-18s %-9s${C_RST} ${C_DIM}|${C_RST} ${C_GRY}%-15s %-10s %-9s${C_RST}\e[K\n" "PID" "PROCESS" "SWAP" "MOUNT" "FILESYSTEM" "USE%"

        local spids=() scomms=() svals=() dmounts=() dnames=() dpcts=()
        while read -r p c v; do spids+=("$p"); scomms+=("$c"); svals+=("$v"); done < <(awk '/^Name:/ {n=$2} /^VmSwap:/ {if($2>0) {split(FILENAME,a,"/"); print a[3], substr(n,1,18), int($2/1024)"M"}}' /proc/[0-9]*/status 2>/dev/null | sort -k3 -nr | head -n 5)
        while read -r pct mnt n; do dpcts+=("$pct"); dmounts+=("$mnt"); dnames+=("$n"); done < <(df -h | grep '^/dev/' | awk '{print $5, substr($6,1,15), substr($1,6,10)}' | sort -nr | head -n 5)

        for i in {0..4}; do
            printf "  %-7s %-18s %-9s ${C_DIM}|${C_RST} %-15s %-10s %-9s\e[K\n" \
                "${spids[i]:--}" "${scomms[i]:--}" "${svals[i]:--}" \
                "${dmounts[i]:--}" "${dnames[i]:--}" "${dpcts[i]:--}"
        done

        _blank; _line
        printf "  ${C_DIM}Live Refresh (2s). Swap Flush safe limit is %s%% RAM. Press [ANY KEY] to exit...${C_RST}\e[K\n" "$SAFE_RAM_PCT"

        if read -t 2 -n 1 -s key; then break; fi
    done
    
    printf "\e[?25h" # Show cursor
    echo
}

# =============================================================================
#  SECTION F -- SETTINGS & AUTOMATION HUB
# =============================================================================
_update_conf() {
    local key="$1" val="$2" conf="/etc/vacuum.conf"
    [[ -f "$conf" ]] || touch "$conf"
    if grep -q "^${key}=" "$conf" 2>/dev/null; then sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$conf"
    else echo "${key}=\"${val}\"" >> "$conf"; fi
    printf -v "$key" "%s" "$val"
}

_prompt_setting() {
    local key="$1" name="$2" sug="$3" regex="$4"
    local val="${!key}" input
    
    printf "  ${C_BLD}%-30s${C_RST} [Current: ${C_CYN}%s${C_RST} | Suggested: ${C_GRY}%s${C_RST}]\n" "$name" "$val" "$sug"
    read -rp "  ❯ Enter new value (or press Enter to keep current): " input
    input="${input:-$val}"
    
    if [[ -n "$regex" && ! "$input" =~ $regex ]]; then _err "Invalid format. Keeping ${val}."
    else _update_conf "$key" "$input"; _ok "Updated $key = $input"; fi
    _blank
}

do_settings() {
    while true; do
        _hdr; _section "Configuration & Behavior Tuning"
        printf "  ${C_WHT}[ 1]${C_RST} Disk Thresholds       ${C_GRY}(Std: %s%%, Agg: %s%%)${C_RST}\n" "$THRESHOLD" "$AGGRESSIVE_THRESHOLD"
        printf "  ${C_WHT}[ 2]${C_RST} Process Reaper Limits ${C_GRY}(Enabled: %s, Kill if > %s%% RAM)${C_RST}\n" "$REAPER_ENABLED" "$REAPER_THRESHOLD"
        printf "  ${C_WHT}[ 3]${C_RST} Safety & App Caches   ${C_GRY}(Safe RAM: %s%%, Caches: %sd)${C_RST}\n" "$SAFE_RAM_PCT" "$CACHE_AGE_DAYS"
        printf "  ${C_WHT}[ 4]${C_RST} Developer Limits      ${C_GRY}(node_modules age: %sd)${C_RST}\n" "$DEV_CACHE_DAYS"
        printf "  ${C_WHT}[ 5]${C_RST} Kernel Memory Tuning  ${C_GRY}(Swap: %s, VFS: %s)${C_RST}\n" "$SWAPPINESS" "$VFS_CACHE_PRESSURE"
        printf "  ${C_WHT}[ 6]${C_RST} Protection / Excludes ${C_GRY}(Paths: %s)${C_RST}\n" "${EXCLUDE_PATHS:-None}"
        printf "  ${C_WHT}[ 0]${C_RST} Back to Main Menu\n"
        _blank; read -rp "  Select category to edit: " opt; _blank

        case "$opt" in
            1) _prompt_setting "THRESHOLD" "Standard Trigger %" "$DEFAULT_THRESHOLD" "^[0-9]+$"; _prompt_setting "AGGRESSIVE_THRESHOLD" "Aggressive Trigger %" "$DEFAULT_AGGRESSIVE" "^[0-9]+$" ;;
            2) _prompt_setting "REAPER_ENABLED" "Process Reaper (true/false)" "false" "^(true|false)$"; _prompt_setting "REAPER_THRESHOLD" "Kill if RAM > %" "$DEFAULT_REAPER_THRESHOLD" "^[0-9]+$" ;;
            3) _prompt_setting "SAFE_RAM_PCT" "Safe RAM limit for Swap %" "$DEFAULT_SAFE_RAM_PCT" "^[0-9]+$"; _prompt_setting "CACHE_AGE_DAYS" "App Cache Age (Days)" "$DEFAULT_CACHE_AGE_DAYS" "^[0-9]+$" ;;
            4) _prompt_setting "DEV_CACHE_DAYS" "node_modules Age (Days)" "$DEFAULT_DEV_CACHE_DAYS" "^[0-9]+$" ;;
            5) _prompt_setting "SWAPPINESS" "vm.swappiness (0-100)" "$DEFAULT_SWAPPINESS" "^[0-9]+$"; _prompt_setting "VFS_CACHE_PRESSURE" "vm.vfs_cache_pressure" "$DEFAULT_VFS_CACHE_PRESSURE" "^[0-9]+$" ;;
            6) _prompt_setting "EXCLUDE_PATHS" "Paths to Protect (space separated)" "$DEFAULT_EXCLUDE_PATHS" "" ;;
            0) return ;;
            *) _err "Invalid option"; sleep 1 ;;
        esac
    done
}

do_automation() {
    local t_svc="/etc/systemd/system/vacuum.timer"
    local m_svc="/etc/systemd/system/vacuum-monitor.service"

    while true; do
        _hdr; _section "Auto Cleanup & Automation Hub"
        
        local t_stat="${C_GRY}Inactive${C_RST}"; local m_stat="${C_GRY}Inactive${C_RST}"
        systemctl is-active --quiet vacuum.timer 2>/dev/null && t_stat="${C_GRN}Active${C_RST}"
        systemctl is-active --quiet vacuum-monitor 2>/dev/null && m_stat="${C_GRN}Active${C_RST}"

        printf "  [ Scheduled Timer ]   Status: %s\n" "$t_stat"
        if [[ "$t_stat" == *Active* ]]; then _kv "Schedule" "$(grep "OnCalendar=" "$t_svc" 2>/dev/null | cut -d'=' -f2 || echo "Unknown")"; fi
        _blank
        printf "  [ Resource Watchdog ] Status: %s\n" "$m_stat"
        if [[ "$m_stat" == *Active* ]]; then _kv "Triggers" "Disk >= ${THRESHOLD}%, Load >= ${LOAD_THRESHOLD}"; fi
        _line; _blank

        printf "  ${C_WHT}[ 1]${C_RST} Configure Scheduled System Timer\n"
        printf "  ${C_WHT}[ 2]${C_RST} Toggle Resource Watchdog Daemon\n"
        printf "  ${C_WHT}[ 3]${C_RST} Disable ALL Automation\n"
        printf "  ${C_WHT}[ 0]${C_RST} Back to Main Menu\n"
        _blank; read -rp "  Select action: " opt; _blank

        local self; self=$(realpath "$0")
        case "$opt" in
            1) 
                printf "  Options: [1] Hourly  [2] Daily  [3] Weekly  [c] Custom\n"
                read -rp "  Select schedule: " s_opt; local cal=""
                case "$s_opt" in 1) cal="hourly" ;; 2) cal="daily" ;; 3) cal="weekly" ;; c|C) read -rp "  Enter systemd OnCalendar string: " cal ;; *) _err "Invalid"; continue ;; esac
                cat > /etc/systemd/system/vacuum.service <<EOF
[Unit]
Description=Vacuum Automated Cleanup
[Service]
Type=oneshot
ExecStart=$self -r -y -q
EOF
                cat > "$t_svc" <<EOF
[Unit]
Description=Vacuum Timer
Requires=vacuum.service
[Timer]
OnCalendar=$cal
Persistent=true
[Install]
WantedBy=timers.target
EOF
                systemctl daemon-reload; systemctl enable --now vacuum.timer >/dev/null 2>&1 || true; _ok "Scheduled timer enabled for: $cal"; sleep 2 ;;
            2)
                if [[ "$m_stat" == *Active* ]]; then
                    systemctl disable --now vacuum-monitor 2>/dev/null || true; rm -f "$m_svc"; systemctl daemon-reload; _ok "Monitor daemon disabled."; sleep 2
                else
                    cat > "$m_svc" <<EOF
[Unit]
Description=Vacuum Resource Watchdog
After=systemd-journald.socket
[Service]
Type=simple
ExecStart=$self --daemon
Restart=always
RestartSec=30
[Install]
WantedBy=multi-user.target
EOF
                    systemctl daemon-reload; systemctl enable --now vacuum-monitor >/dev/null 2>&1 || true; _ok "Resource monitor enabled. Interval: ${MONITOR_INTERVAL}s"; sleep 2
                fi ;;
            3)
                systemctl disable --now vacuum.timer vacuum-monitor 2>/dev/null || true; rm -f "$t_svc" /etc/systemd/system/vacuum.service "$m_svc" 2>/dev/null || true
                systemctl daemon-reload; _ok "All automation removed."; sleep 2 ;;
            0) return ;;
        esac
    done
}

do_daemon() {
    while true; do
        local p=$(_disk_p) load=$(awk '{ print $1 }' /proc/loadavg 2>/dev/null || echo 0)
        local trig=$(awk -v l="$load" -v t="$LOAD_THRESHOLD" 'BEGIN { print (l+0>=t+0)?1:0 }' 2>/dev/null || echo 0)
        if [[ "${p:-0}" -ge "${THRESHOLD:-85}" ]] || [[ "${trig:-0}" -eq 1 ]]; then
            V_MONITOR_MODE=true V_QUIET=true V_AUTO_YES=true _cleanup
            sleep 3600
        else sleep "$MONITOR_INTERVAL"; fi
    done
}

# =============================================================================
#  SECTION G -- ROUTING
# =============================================================================
do_interactive() {
    while true; do
        _hdr; _section "Main Operations"
        printf "  ${C_WHT}[ 1]${C_RST} Execute Standard Optimization\n"
        printf "  ${C_WHT}[ 2]${C_RST} Execute Aggressive Deep Clean\n"
        printf "  ${C_WHT}[ 3]${C_RST} Execute ${C_PRP}Developer Clean${C_RST} ${C_GRY}(Stale Node/DB/Docker)${C_RST}\n"
        printf "  ${C_WHT}[ 4]${C_RST} Enable ${C_RED}Maximum Performance${C_RST} Profile\n"
        printf "  ${C_WHT}[ 5]${C_RST} Live Telemetry & Resource Dashboard\n"
        printf "  ${C_WHT}[ 6]${C_RST} Auto Cleanup & Automation Hub\n"
        printf "  ${C_WHT}[ 7]${C_RST} Configure Settings & Tuning\n"
        printf "  ${C_WHT}[ 0]${C_RST} Exit\n"
        _blank; read -rp "  Select an option: " opt; _blank

        case "$opt" in
            1) _root; _cleanup; read -rp "  Press Enter to return..." _ ;;
            2) _root; V_AGG=true; _cleanup; read -rp "  Press Enter to return..." _ ;;
            3) _root; V_DEV=true; _cleanup; read -rp "  Press Enter to return..." _ ;;
            4) _root; V_PERF=true REAPER_ENABLED=true _cleanup; read -rp "  Press Enter to return..." _ ;;
            5) do_dashboard ;;
            6) _root; do_automation ;;
            7) _root; do_settings ;;
            0) echo; exit 0 ;;
            *) _err "Invalid selection"; sleep 1 ;;
        esac
    done
}

[[ $# -eq 0 ]] && { do_interactive; exit 0; }
ACTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--interactive) ACTION="interactive" ;;
        -r|--run)         ACTION="run" ;;
        -a|--aggressive)  ACTION="agg" ;;
        -D|--developer)   ACTION="dev" ;;
        -p|--perf)        ACTION="perf" ;;
        -s|--status)      ACTION="status" ;;
        -y|--yes)         V_AUTO_YES=true ;;
        -q|--quiet)       V_QUIET=true ;;
        --daemon)         ACTION="daemon" ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac; shift
done
[[ -z "$ACTION" ]] && ACTION="run"
case "$ACTION" in
    interactive) do_interactive ;;
    run)         _root; _cleanup ;;
    agg)         _root; V_AGG=true; _cleanup ;;
    dev)         _root; V_DEV=true; _cleanup ;;
    perf)        _root; V_PERF=true REAPER_ENABLED=true; _cleanup ;;
    status)      do_dashboard ;;
    daemon)      _root; do_daemon ;;
esac
