#!/usr/bin/env bash

set -euo pipefail

# =============================================================================
#  SECTION A -- DEFAULT CONFIGURATION
# =============================================================================
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
LOG_FILE="/var/log/vacuum.log"
REPORT_DIR="/var/log/vacuum-reports"
EXCLUDE_USERS="root"

[[ -f /etc/vacuum.conf ]] && source /etc/vacuum.conf || true

# =============================================================================
#  SECTION B -- COLORS
# =============================================================================
if [[ -t 1 ]] && tput colors &>/dev/null 2>&1; then
    RST=$'\e[0m';  BLD=$'\e[1m';  DIM=$'\e[2m'
    RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'
    MAG=$'\e[35m'; CYN=$'\e[36m'; WHT=$'\e[97m'; GRY=$'\e[90m'
    BRED=$'\e[91m'; BGRN=$'\e[92m'; BYLW=$'\e[93m'; BBLU=$'\e[94m'
    BCYN=$'\e[96m'
else
    RST=''; BLD=''; DIM=''
    RED=''; GRN=''; YLW=''; BLU=''
    MAG=''; CYN=''; WHT=''; GRY=''
    BRED=''; BGRN=''; BYLW=''; BBLU=''; BCYN=''
fi

# =============================================================================
#  SECTION C -- UI ENGINE  (ASCII only, no box-drawing chars)
# =============================================================================

_tw()   { tput cols 2>/dev/null || echo 78; }
_raw()  { printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'; }
_rlen() { local s; s=$(_raw "$1"); echo "${#s}"; }

_line()  { local w; w=$(_tw); printf "${DIM}"; printf '%*s' "$w" '' | tr ' ' '-'; printf "${RST}\n"; }
_dline() { local w; w=$(_tw); printf "${DIM}"; printf '%*s' "$w" '' | tr ' ' '='; printf "${RST}\n"; }
_blank() { echo; }

_center() {
    local text="$1" tw pad len
    tw=$(_tw)
    len=$(_rlen "$text")
    pad=$(( (tw - len) / 2 ))
    [[ $pad -lt 0 ]] && pad=0 || true
    printf "%${pad}s%s\n" "" "$text"
}

_hdr() {
    clear; _blank; _dline
    _center "${BLD}${CYN}VACUUM  --  System Optimizer and Memory Suite${RST}"
    _dline; _blank
}

_section() {
    _blank
    printf " ${BLD}${BLU}>>> %s${RST}\n" "$1"
    _line
}

_ok()   { printf " ${BGRN}[  OK  ]${RST}  %s\n"             "$*"; }
_err()  { printf " ${BRED}[ FAIL ]${RST}  ${RED}%s${RST}\n" "$*" >&2; }
_warn() { printf " ${BYLW}[ WARN ]${RST}  ${YLW}%s${RST}\n" "$*"; }
_info() { printf " ${BCYN}[ INFO ]${RST}  ${CYN}%s${RST}\n" "$*"; }
_hint() { printf " ${MAG}[ HINT ]${RST}  ${DIM}%s${RST}\n"  "$*"; }
_step() { printf " ${BLU}[  >>  ]${RST}  %-46s"             "$1 ..."; }
_done() { printf " ${BGRN}Done${RST}\n"; }
_skip() { printf " ${GRY}Skipped${RST}\n"; }

_kv()   { printf "  ${GRY}%-34s${RST}  %s\n" "$1" "$2"; }

# Progress bar -- ASCII only, no unicode block chars
_bar() {
    local p=0 w=26 label="" c f e filled empty
    p="${1:-0}"; label="${2:-}"
    f=0; e=$w
    if [[ $p -gt 0 ]]; then
        f=$(( p * w / 100 ))
        [[ $f -gt $w ]] && f=$w || true
        e=$(( w - f ))
        [[ $e -lt 0 ]] && e=0 || true
    fi
    c="$BGRN"
    [[ $p -ge 60 ]] && c="$BYLW" || true
    [[ $p -ge 80 ]] && c="$BRED" || true
    filled=""
    empty=""
    [[ $f -gt 0 ]] && filled=$(printf '%*s' "$f" '' | tr ' ' '#') || true
    [[ $e -gt 0 ]] && empty=$(printf '%*s'  "$e" '' | tr ' ' '.') || true
    printf "${c}[%s%s]${RST} ${BLD}%3d%%${RST}" "$filled" "$empty" "$p"
    [[ -n "$label" ]] && printf "  ${GRY}%s${RST}" "$label" || true
}

_root() { [[ $EUID -eq 0 ]] || { _err "Root required. Use: sudo vacuum"; exit 1; }; }

# =============================================================================
#  SECTION D -- ASCII TABLE RENDERER
#  Columns sized dynamically from terminal width.
#  No box-drawing characters -- uses | + - only.
# =============================================================================

# Returns three column widths fitting current terminal
_col_widths() {
    local tw avail c1 c2 c3
    tw=$(_tw)
    avail=$(( tw - 10 ))
    [[ $avail -lt 36 ]] && avail=36 || true
    c1=$(( avail * 34 / 100 ))
    c2=$(( avail * 33 / 100 ))
    c3=$(( avail - c1 - c2 ))
    [[ $c1 -lt 12 ]] && c1=12 || true
    [[ $c2 -lt 12 ]] && c2=12 || true
    [[ $c3 -lt 10 ]] && c3=10 || true
    # Ensures 'read' correctly processes output without returning an EOF error
    printf '%d %d %d\n' "$c1" "$c2" "$c3" 
}

_t_hrule() {
    local c1 c2 c3
    read -r c1 c2 c3 < <(_col_widths) || true
    printf "  +"
    printf '%*s' "$c1" '' | tr ' ' '-'; printf "+"
    printf '%*s' "$c2" '' | tr ' ' '-'; printf "+"
    printf '%*s' "$c3" '' | tr ' ' '-'; printf "+\n"
}

_t_cell() {
    local text="$1" width="$2" hdr="${3:-0}"
    local clean pad
    clean=$(_raw "$text")
    pad=$(( width - ${#clean} - 1 ))
    [[ $pad -lt 0 ]] && pad=0 || true
    if [[ $hdr -eq 1 ]]; then
        printf " ${BLD}${BLU}%s${RST}%*s" "$text" "$pad" ""
    else
        printf " %s%*s" "$text" "$pad" ""
    fi
}

_thead() {
    local h1="$1" h2="$2" h3="$3"
    local c1 c2 c3
    read -r c1 c2 c3 < <(_col_widths) || true
    _t_hrule
    printf "  |"; _t_cell "$h1" "$c1" 1; printf "|"
    printf    ""; _t_cell "$h2" "$c2" 1; printf "|"
    printf    ""; _t_cell "$h3" "$c3" 1; printf "|\n"
    _t_hrule
}

_trow() {
    local v1="$1" v2="$2" v3="$3"
    local c1 c2 c3
    read -r c1 c2 c3 < <(_col_widths) || true
    printf "  |"; _t_cell "$v1" "$c1" 0; printf "|"
    printf    ""; _t_cell "$v2" "$c2" 0; printf "|"
    printf    ""; _t_cell "$v3" "$c3" 0; printf "|\n"
}

_tfoot() { _t_hrule; }

# =============================================================================
#  SECTION E -- UTILITIES
# =============================================================================
_cmd() { $V_DRY || eval "$@" >/dev/null 2>&1 || true; }
_log() { printf "[%s][%s] %s\n" "$(date +"%F %T")" "$1" "$2" >> "$LOG_FILE" 2>/dev/null || true; }

_stats() {
    local pct=0 avail=0 raw
    raw=$(df / --output=pcent,avail -BM 2>/dev/null | tail -1 | tr -dc '0-9 ' | xargs 2>/dev/null || true)
    [[ -n "$raw" ]] && read -r pct avail <<< "$raw" || true
    printf '%d %d\n' "${pct:-0}" "${avail:-0}"
}

# Disk usage as separate values -- no awk parenthesis issues
_disk_used_pct() {
    df / --output=pcent 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0
}
_disk_free_human() {
    df -h / 2>/dev/null | awk 'NR==2 { print $4 }' || echo "?"
}
_disk_used_human() {
    df -h / 2>/dev/null | awk 'NR==2 { print $3 }' || echo "?"
}
_disk_total_human() {
    df -h / 2>/dev/null | awk 'NR==2 { print $2 }' || echo "?"
}

# RAM helpers -- plain awk, no nested parens near shell quoting
_ram_pct() {
    free 2>/dev/null | awk '/^Mem:/ { if ($2 > 0) printf "%d", $3 * 100 / $2; else print 0 }' || echo 0
}
_ram_label() {
    free -h 2>/dev/null | awk '/^Mem:/ { printf "%s used / %s total", $3, $2 }' || echo ""
}
_swap_pct() {
    free 2>/dev/null | awk '/^Swap:/ { if ($2 > 0) printf "%d", $3 * 100 / $2; else print 0 }' || echo 0
}
_swap_label() {
    free -h 2>/dev/null | awk '/^Swap:/ { if ($2 == "0B") print "No swap configured"; else printf "%s used / %s total", $3, $2 }' || echo "No swap configured"
}
_ram_total_mb() {
    free -m 2>/dev/null | awk '/^Mem:/ { print $2 }' || echo 0
}
_ram_used_mb() {
    free -m 2>/dev/null | awk '/^Mem:/ { print $3 }' || echo 0
}
_swap_total_mb() {
    free -m 2>/dev/null | awk '/^Swap:/ { print $2 }' || echo 0
}

# Next scheduler run -- parses systemctl list-timers output safely
_next_run() {
    local raw="" result=""
    if ! systemctl is-active --quiet vacuum.timer 2>/dev/null; then
        echo "Scheduler not active"
        return
    fi
    
    # Grab the raw, header-less line in standard English
    raw=$(LC_ALL=C systemctl list-timers vacuum.timer --all --no-pager --no-legend 2>/dev/null || true)
    
    [[ -z "$raw" ]] && { echo "Calculating..."; return; } || true
    
    result=$(echo "$raw" | awk '{
        # If systemd has not calculated the next run yet, it outputs n/a
        if ($1 == "n/a") {
            print "Calculating..."
            exit
        }
        
        # $3 contains the 24-hour time (e.g. 17:30:00). We split it by the colon.
        split($3, t, ":")
        h = t[1] + 0
        
        # Determine AM or PM
        ampm = (h >= 12) ? "PM" : "AM"
        
        # Convert 24-hour hour to 12-hour format
        if (h == 0) {
            h = 12
        } else if (h > 12) {
            h = h - 12
        }
        
        # Format the new 12-hour time string (e.g. 05:30:00 PM)
        time_12 = sprintf("%02d:%s:%s %s", h, t[2], t[3], ampm)
        
        # Combine Day, Date, and the new 12-hour Time
        dt = $1 " " $2 " " time_12
        
        # We will loop through the whole line and look for the word "left".
        # Because we used --no-legend, the countdown is ALWAYS the last thing on the line.
        left_val = ""
        for (i=4; i<=NF; i++) {
            if ($i == "left") {
                # Just grab the two words right before "left" (e.g., 2min left, or 1h 30min left)
                # If the word two spaces back is IST/UTC, just grab the one word before left.
                if ($(i-2) ~ /^[0-9]/) {
                    left_val = $(i-2) " " $(i-1) " left"
                } else {
                    left_val = $(i-1) " left"
                }
                break
            }
        }
        
        # Combine the Date/Time with the countdown in brackets
        if (left_val != "") {
            print dt "  (" left_val ")"
        } else {
            print dt
        }
    }' 2>/dev/null || true)
    
    [[ -z "$result" ]] && result="Calculating..." || true
    echo "$result"
}

# =============================================================================
#  SECTION F -- NOTIFICATION ENGINE
# =============================================================================
_notify() {
    [[ "${NOTIFY:-true}" == "true" ]] || return 0
    local title="$1" body="$2" user="" uid="" dbus=""
    user=$(ps -eo euser,comm 2>/dev/null | awk '$2~/^(gnome-session|ksmserver|xfce4-session|cinnamon-sessio|mate-session|startplasma-)/ { print $1; exit }')
    [[ -z "$user" ]] && user=$(who 2>/dev/null | awk '$2~/:[0-9]/ { print $1; exit }') || true
    [[ -z "$user" ]] && user=$(getent passwd 2>/dev/null | awk -F: '$3>=1000 && $3!=65534 { print $1; exit }') || true
    [[ -z "$user" ]] && return 1 || true
    uid=$(id -u "$user" 2>/dev/null) || return 1
    dbus="unix:path=/run/user/${uid}/bus"
    local d
    for d in :0 :1 :0.0 ""; do
        sudo -u "$user" DISPLAY="$d" DBUS_SESSION_BUS_ADDRESS="$dbus" \
            notify-send -a "Vacuum" "$title" "$body" >/dev/null 2>&1 && return 0
    done
    return 1
}

# =============================================================================
#  SECTION G -- MEMORY RECLAMATION ENGINE
#  All 13 subsystems. Automatically included in every cleanup run.
# =============================================================================
_do_all_memory_cleanup() {
    local ram_total=1 ram_used=0 ram_pct=0 swap_total=0

    ram_total=$(_ram_total_mb); [[ ${ram_total:-0} -le 0 ]] && ram_total=1 || true
    ram_used=$(_ram_used_mb)
    swap_total=$(_swap_total_mb)
    ram_pct=$(( (ram_used * 100) / ram_total ))

    # 1 -- Sync dirty buffers
    $V_QUIET || _step "Synchronising filesystem dirty buffers to disk"
    sync 2>/dev/null || true; sync 2>/dev/null || true
    $V_QUIET || _done

    # 2 -- Drop page cache level 1
    $V_QUIET || _step "Releasing page cache  [level 1 -- file data]"
    echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
    $V_QUIET || _done

    # 3 -- Drop dentries and inodes level 2
    $V_QUIET || _step "Releasing dentry and inode cache  [level 2]"
    echo 2 > /proc/sys/vm/drop_caches 2>/dev/null || true
    $V_QUIET || _done

    # 4 -- Full kernel cache purge level 3
    $V_QUIET || _step "Full kernel cache purge  [level 3 -- page + dentry + inode]"
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    $V_QUIET || _done

    # 5 -- Compact kernel memory pages
    $V_QUIET || _step "Compacting kernel memory pages  [reduce fragmentation]"
    [[ -f /proc/sys/vm/compact_memory ]] && echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
    $V_QUIET || _done

    # 6 -- vm.swappiness
    $V_QUIET || _step "Tuning vm.swappiness to 10  [prefer RAM over swap]"
    sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
    $V_QUIET || _done

    # 7 -- vm.vfs_cache_pressure
    $V_QUIET || _step "Tuning vm.vfs_cache_pressure to 50  [balanced reclaim]"
    sysctl -w vm.vfs_cache_pressure=50 >/dev/null 2>&1 || true
    $V_QUIET || _done

    # 8 -- Dirty page write-back ratios
    $V_QUIET || _step "Tuning dirty page write-back ratios  [dirty=10 bg=5]"
    sysctl -w vm.dirty_ratio=10 >/dev/null 2>&1 || true
    sysctl -w vm.dirty_background_ratio=5 >/dev/null 2>&1 || true
    $V_QUIET || _done

    # 9 -- Transparent HugePages
    $V_QUIET || _step "Setting Transparent HugePages to madvise  [reduce latency]"
    [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]] && \
        echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    [[ -f /sys/kernel/mm/transparent_hugepage/defrag ]] && \
        echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
    $V_QUIET || _done

    # 10 -- OOM score adjustment for critical kernel threads
    $V_QUIET || _step "Protecting critical kernel threads from OOM killer"
    local pf pcomm
    for pf in /proc/[0-9]*/oom_score_adj; do
        [[ -f "$pf" ]] || continue
        pcomm=""
        pcomm=$(cat "${pf%oom_score_adj}comm" 2>/dev/null || true)
        if [[ "$pcomm" =~ ^(systemd|kthreadd|ksoftirqd|kworker|migration|rcu_) ]]; then
            echo -500 > "$pf" 2>/dev/null || true
        fi
    done
    $V_QUIET || _done

    # 11 -- Swap flush (safe -- skip if RAM > 75%)
    if [[ ${swap_total:-0} -gt 0 ]] && [[ $(swapon --show 2>/dev/null | wc -l) -gt 0 ]]; then
        if [[ ${ram_pct:-0} -lt 75 ]]; then
            $V_QUIET || _step "Flushing and resetting swap space  [RAM at ${ram_pct}% -- safe]"
            swapoff -a 2>/dev/null && swapon -a 2>/dev/null || true
            $V_QUIET || _done
        else
            $V_QUIET || _step "Swap flush deferred  [RAM at ${ram_pct}% -- OOM prevention]"
            $V_QUIET || _skip
        fi
    else
        $V_QUIET || _step "Swap flush check"
        $V_QUIET || printf " ${GRY}No active swap detected${RST}\n"
    fi

    # 12 -- cgroup slab reclaim
    $V_QUIET || _step "Requesting slab reclaim via cgroup memory.force_empty"
    if [[ -d /sys/fs/cgroup/memory ]]; then
        local f
        while IFS= read -r f; do
            echo 0 > "$f" 2>/dev/null || true
        done < <(find /sys/fs/cgroup/memory -name "memory.force_empty" 2>/dev/null)
    fi
    $V_QUIET || _done

    # 13 -- GPU/DRM memory objects
    $V_QUIET || _step "Requesting GPU/DRM memory object shrink  [if applicable]"
    local gf
    for gf in /sys/class/drm/*/shrink_memory; do
        [[ -f "$gf" ]] && echo 1 > "$gf" 2>/dev/null || true
    done
    $V_QUIET || _done
}

# =============================================================================
#  SECTION H -- MAIN CLEANUP ENGINE
#  Direct runs (-r / -a) always execute all phases regardless of threshold.
#  Threshold applies only when V_MONITOR_MODE=true (daemon-triggered).
# =============================================================================
V_AGG=false; V_QUIET=false; V_DRY=false; V_MONITOR_MODE=false
V_LOCK="/var/lock/vacuum.lock"

_cleanup() {
    exec 200>"$V_LOCK"
    flock -n 200 || { _err "Another Vacuum instance is currently running."; exit 1; }
    trap 'flock -u 200; rm -f "$V_LOCK"' EXIT

    mkdir -p "$REPORT_DIR"
    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"

    local pb=0 am=0 ts="" ts_epoch=0
    read -r pb am < <(_stats) || true
    ts=$(date +"%F %T")
    ts_epoch=$(date +%s)

    # In monitor mode, respect threshold. In direct mode, always run.
    if $V_MONITOR_MODE && [[ ${pb:-0} -lt ${THRESHOLD:-85} ]] && ! $V_AGG && ! $V_DRY; then
        $V_QUIET || {
            _info "Disk at ${pb}% -- below monitor threshold of ${THRESHOLD}%."
            _info "No action required at this time."
        }
        return 0
    fi

    [[ ${pb:-0} -ge ${AGGRESSIVE_THRESHOLD:-95} ]] && V_AGG=true || true

    local mode_label="Standard"
    $V_AGG && mode_label="Aggressive" || true
    $V_DRY && mode_label="Simulation (Dry-Run)" || true

    _log INFO "Start | Mode: $mode_label | Disk: ${pb}%"
    $V_QUIET || {
        _hdr
        _section "Cleanup Session -- Configuration"
        _kv "Execution Mode"   "$mode_label"
        _kv "Disk Utilisation" "${pb}%"
        _kv "Available Space"  "${am} MB"
        _kv "Session Started"  "$ts"
        _blank
    }

    # Phase 1 -- Journals and Logs
    $V_QUIET || _section "Phase 1 of 10 -- System Journals and Log Files"
    $V_QUIET || _step "Vacuuming systemd journal  [size cap: ${JOURNAL_LIMIT}]"
    journalctl --vacuum-size="$JOURNAL_LIMIT" >/dev/null 2>&1 || true
    $V_QUIET || _done
    $V_QUIET || _step "Vacuuming systemd journal  [time cap: ${JOURNAL_DAYS} days]"
    journalctl --vacuum-time="${JOURNAL_DAYS}d" >/dev/null 2>&1 || true
    journalctl --rotate >/dev/null 2>&1 || true
    $V_QUIET || _done
    $V_QUIET || _step "Removing compressed and rotated log archives"
    find /var/log -type f \( -name '*.gz' -o -name '*.bz2' -o -name '*.xz' \) -mtime +7 -delete 2>/dev/null || true
    find /var/log -type f -name '*.log.*' -mtime +30 -delete 2>/dev/null || true
    find /var/log -type f -name '*.old' -delete 2>/dev/null || true
    $V_QUIET || _done
    $V_QUIET || _step "Purging crash reports and core dump archives"
    command -v coredumpctl &>/dev/null && coredumpctl clean >/dev/null 2>&1 || true
    rm -rf /var/crash/* /var/lib/systemd/coredump/* 2>/dev/null || true
    $V_QUIET || _done

    # Phase 2 -- Package Manager
    $V_QUIET || _section "Phase 2 of 10 -- Package Manager Caches"
    $V_QUIET || _step "Removing downloaded packages and orphaned dependencies"
    if command -v apt-get &>/dev/null; then
        apt-get autoclean -y >/dev/null 2>&1 || true
        apt-get autoremove --purge -y >/dev/null 2>&1 || true
        apt-get clean >/dev/null 2>&1 || true
        rm -rf /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/* 2>/dev/null || true
        if $V_AGG; then
            local old_k=""
            old_k=$(dpkg -l 'linux-image-*' 'linux-headers-*' 'linux-modules-*' 2>/dev/null \
                | awk '/^ii/ { print $2 }' \
                | grep -vE "$(uname -r | sed 's/-[a-z].*//g')" \
                | grep -Ev 'linux-(image|headers)-generic' 2>/dev/null || true)
            [[ -n "$old_k" ]] && apt-get remove --purge -y $old_k >/dev/null 2>&1 || true
        fi
    elif command -v dnf &>/dev/null; then
        dnf autoremove -y >/dev/null 2>&1 || true
        dnf clean all >/dev/null 2>&1 || true
        rm -rf /var/cache/dnf/* 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        yum autoremove -y >/dev/null 2>&1 || true
        yum clean all >/dev/null 2>&1 || true
        rm -rf /var/cache/yum/* 2>/dev/null || true
    elif command -v pacman &>/dev/null; then
        pacman -Sc --noconfirm >/dev/null 2>&1 || true
        local orph=""
        orph=$(pacman -Qdtq 2>/dev/null || true)
        [[ -n "$orph" ]] && pacman -Rns $orph --noconfirm >/dev/null 2>&1 || true
        $V_AGG && pacman -Scc --noconfirm >/dev/null 2>&1 || true
    elif command -v zypper &>/dev/null; then
        zypper clean --all >/dev/null 2>&1 || true
    fi
    $V_QUIET || _done

    # Phase 3 -- Temporary Files
    $V_QUIET || _section "Phase 3 of 10 -- Temporary and Junk Files"
    $V_QUIET || _step "Clearing /tmp and /var/tmp directories"
    find /tmp /var/tmp -mindepth 1 \( -name '.X*' -o -name '.ICE*' \) -prune -o -delete 2>/dev/null || true
    $V_QUIET || _done
    $V_QUIET || _step "Removing stale /run/user session remnants"
    local stale_d uid_num
    while IFS= read -r stale_d; do
        uid_num=$(basename "$stale_d")
        id "$uid_num" &>/dev/null || rm -rf "$stale_d" 2>/dev/null || true
    done < <(find /run/user -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
    $V_QUIET || _done
    $V_QUIET || _step "Clearing manual page cache"
    rm -rf /var/cache/man/* 2>/dev/null || true
    $V_QUIET || _done

    # Phase 4 -- User Profile Caches
    $V_QUIET || _section "Phase 4 of 10 -- User Profile and Application Caches"
    $V_QUIET || _step "Processing all non-root user profiles"
    local u h
    while IFS=: read -r u h; do
        [[ " $EXCLUDE_USERS " =~ " $u " ]] && continue || true
        [[ -d "$h" ]] || continue
        [[ -d "$h/.cache/thumbnails" ]] && rm -rf "$h/.cache/thumbnails/"* 2>/dev/null || true
        $V_AGG && [[ -f "$h/.local/share/recently-used.xbel" ]] && \
            truncate -s 0 "$h/.local/share/recently-used.xbel" 2>/dev/null || true
        if [[ -d "$h/.cache" ]]; then
            if $V_AGG; then
                find "$h/.cache" -mindepth 1 -delete 2>/dev/null || true
            else
                find "$h/.cache" -mindepth 1 -atime "+${CACHE_AGE_DAYS}" -delete 2>/dev/null || true
            fi
        fi
        [[ -d "$h/.local/share/Trash" ]] && \
            rm -rf "$h/.local/share/Trash/files/"* "$h/.local/share/Trash/info/"* 2>/dev/null || true
        [[ -d "$h/.npm/_cacache" ]]    && rm -rf "$h/.npm/_cacache"    2>/dev/null || true
        [[ -d "$h/.npm/tmp" ]]         && rm -rf "$h/.npm/tmp"         2>/dev/null || true
        [[ -d "$h/.cache/pip" ]]       && rm -rf "$h/.cache/pip"       2>/dev/null || true
        [[ -d "$h/.cache/yarn" ]]      && rm -rf "$h/.cache/yarn"      2>/dev/null || true
        [[ -d "$h/.composer/cache" ]]  && rm -rf "$h/.composer/cache"  2>/dev/null || true
        if $V_AGG; then
            [[ -d "$h/.cache/go-build" ]]       && rm -rf "$h/.cache/go-build"       2>/dev/null || true
            [[ -d "$h/.gradle/caches" ]]         && rm -rf "$h/.gradle/caches"        2>/dev/null || true
            [[ -d "$h/.cargo/registry/cache" ]]  && rm -rf "$h/.cargo/registry/cache" 2>/dev/null || true
            [[ -d "$h/.m2/repository" ]] && \
                find "$h/.m2/repository" -name '*.lastUpdated' -delete 2>/dev/null || true
            [[ -d "$h/.config/Code/CachedData" ]] && \
                rm -rf "$h/.config/Code/CachedData" 2>/dev/null || true
            local ff_d
            while IFS= read -r ff_d; do
                rm -rf "$ff_d/entries/"* 2>/dev/null || true
            done < <(find "$h/.mozilla/firefox" -type d -name "cache2" 2>/dev/null)
            local br
            for br in ".config/google-chrome" ".config/chromium" ".config/brave-browser"; do
                [[ -d "$h/$br" ]] && \
                    find "$h/$br" -type d -name 'Cache' -exec rm -rf {}/* \; 2>/dev/null || true
            done
            [[ -d "$h/.var/app" ]] && \
                find "$h/.var/app" -type d -name 'cache' -exec rm -rf {}/* \; 2>/dev/null || true
        fi
    done < <(getent passwd 2>/dev/null | awk -F: '$3>=1000 && $3!=65534 { print $1":"$6 }')
    $V_QUIET || _done

    # Phase 5 -- Snap
    if command -v snap &>/dev/null; then
        $V_QUIET || _section "Phase 5 of 10 -- Snap Package Artifacts"
        $V_QUIET || _step "Removing disabled and superseded Snap revisions"
        snap list --all 2>/dev/null \
            | awk '/disabled/ { print $1, $3 }' \
            | while read -r sn rev; do
                snap remove "$sn" --revision="$rev" 2>/dev/null || true
              done
        $V_QUIET || _done
    fi

    # Phase 6 -- Flatpak
    if command -v flatpak &>/dev/null; then
        $V_QUIET || _section "Phase 6 of 10 -- Flatpak Unused Runtimes"
        $V_QUIET || _step "Uninstalling unused Flatpak runtimes and extensions"
        flatpak uninstall --unused -y >/dev/null 2>&1 || true
        $V_QUIET || _done
    fi

    # Phase 7 -- Container Engines
    if command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
        $V_QUIET || _section "Phase 7 of 10 -- Docker Artifacts"
        $V_QUIET || _step "Pruning Docker images, containers, networks and build cache"
        if $V_AGG; then
            docker system prune -af --volumes >/dev/null 2>&1 || true
        else
            docker system prune -f >/dev/null 2>&1 || true
        fi
        docker builder prune -af >/dev/null 2>&1 || true
        $V_QUIET || _done
    fi
    if command -v podman &>/dev/null; then
        $V_QUIET || _section "Phase 7b -- Podman Artifacts"
        $V_QUIET || _step "Pruning Podman images, containers and volumes"
        if $V_AGG; then
            podman system prune -af --volumes >/dev/null 2>&1 || true
        else
            podman system prune -f >/dev/null 2>&1 || true
        fi
        $V_QUIET || _done
    fi

    # Phase 8 -- SSD TRIM
    $V_QUIET || _section "Phase 8 of 10 -- Storage Optimisation"
    $V_QUIET || _step "Issuing TRIM command to SSD/NVMe devices via fstrim"
    command -v fstrim &>/dev/null && fstrim -av >/dev/null 2>&1 || true
    $V_QUIET || _done

    # Phase 9 -- Locale and Prelink (aggressive only)
    if $V_AGG; then
        $V_QUIET || _section "Phase 9 of 10 -- System Locale and Prelink Cleanup"
        if command -v localepurge &>/dev/null; then
            $V_QUIET || _step "Purging unused system locale data"
            localepurge >/dev/null 2>&1 || true
            $V_QUIET || _done
        fi
        if command -v prelink &>/dev/null; then
            $V_QUIET || _step "Reverting prelinked binary modifications"
            prelink -ua >/dev/null 2>&1 || true
            $V_QUIET || _done
        fi
    fi

    # Phase 10 -- Complete Memory Reclamation (auto, always included)
    $V_QUIET || _section "Phase 10 of 10 -- Complete Memory Reclamation  [Auto]"
    _do_all_memory_cleanup

    # Final report
    local pa=0 aa=0 freed=0 dur=0
    read -r pa aa < <(_stats) || true
    freed=$(( aa - am )); [[ $freed -lt 0 ]] && freed=0 || true
    dur=$(( $(date +%s) - ts_epoch )) || dur=0
    $V_DRY && { pa=$pb; freed=0; } || true

    {
        printf "Vacuum Report -- %s\nMode: %s\nDisk: %s%% -> %s%%\nFreed: %s MB\nDuration: %ss\n" \
               "$ts" "$mode_label" "$pb" "$pa" "$freed" "$dur"
    } > "$REPORT_DIR/$(date +%Y%m%d-%H%M%S).log" 2>/dev/null || true
    ls -t "$REPORT_DIR/"*.log 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null || true
    _log INFO "Done | ${pb}% -> ${pa}% | Freed: ${freed}MB | ${dur}s"

    $V_QUIET || {
        _section "Session Summary"
        _kv "Mode Applied"      "$mode_label"
        _kv "Disk Before"       "${pb}%"
        _kv "Disk After"        "${pa}%"
        _kv "Storage Reclaimed" "${BGRN}${BLD}${freed} MB${RST}"
        _kv "Duration"          "${dur} seconds"
        _kv "Completed At"      "$(date +"%F %T")"
        _blank
        _ok "Cleanup session completed successfully."
        _blank
    }

    $V_DRY || _notify "Vacuum -- Cleanup Complete" \
        "Mode: ${mode_label} | Disk: ${pb}% to ${pa}% | Freed: ${freed} MB in ${dur}s"
}

# =============================================================================
#  SECTION I -- STANDALONE MEMORY OPTIMIZER  (-m / --ram)
# =============================================================================
do_ram_optimizer() {
    _hdr
    _section "Memory Reclamation -- Subsystem Reference"

    _thead "Memory Subsystem" "What Is Cleaned" "Expected Benefit"
    _trow "Page Cache"         "File data buffered in RAM"           "Frees the largest RAM consumer"
    _trow "Dentry Cache"       "Directory path lookup table"         "Reduces kernel call overhead"
    _trow "Inode Cache"        "Open file metadata structures"       "Reclaims kernel slab memory"
    _trow "Kernel Slabs"       "Allocated but idle kernel objects"   "Reduces memory fragmentation"
    _trow "Swap Space"         "Pages relocated from RAM to disk"    "Restores swap availability"
    _trow "Dirty Buffers"      "Unflushed filesystem write buffers"  "Guarantees data integrity"
    _trow "vm.swappiness"      "Kernel swap aggressiveness to 10"   "Prefers RAM over swap"
    _trow "vfs_cache_pressure" "VFS cache reclaim rate to 50"       "Balanced inode/dentry reclaim"
    _trow "dirty_ratio"        "Max dirty page ratio 10 / bg 5"     "Faster write-back flushing"
    _trow "THP defrag"         "Transparent HugePage defrag"         "Eliminates latency spikes"
    _trow "OOM Score Adj"      "Out-of-memory kill priorities"       "Protects critical processes"
    _trow "cgroup Slabs"       "Per-cgroup slab cache objects"       "Releases container memory"
    _trow "GPU/DRM Objects"    "Graphics driver memory cache"        "Reclaims VRAM-mapped pages"
    _tfoot

    _section "Current Memory State"
    local rm_pct sw_pct sw_total
    rm_pct=$(_ram_pct);   [[ -z "$rm_pct" ]] && rm_pct=0 || true
    sw_total=$(_swap_total_mb); [[ -z "$sw_total" ]] && sw_total=0 || true
    sw_pct=0; [[ $sw_total -gt 0 ]] && sw_pct=$(_swap_pct) || true

    printf "  %-22s " "RAM Usage"
    _bar "$rm_pct" "$(_ram_label)"
    _blank
    printf "  %-22s " "Swap Usage"
    _bar "$sw_pct" "$(_swap_label)"
    _blank
    _kv "Load Average  (1m / 5m / 15m)" "$(awk '{ print $1" / "$2" / "$3 }' /proc/loadavg 2>/dev/null || echo '?')"
    _kv "System Uptime"                  "$(uptime -p 2>/dev/null | sed 's/up //' || echo '?')"

    _section "Executing All Memory Reclamation Procedures"
    _do_all_memory_cleanup

    _section "Memory State -- Post Optimisation"
    rm_pct=$(_ram_pct); [[ -z "$rm_pct" ]] && rm_pct=0 || true
    sw_pct=0; [[ $sw_total -gt 0 ]] && sw_pct=$(_swap_pct) || true

    printf "  %-22s " "RAM Usage"
    _bar "$rm_pct" "$(_ram_label)"
    _blank
    printf "  %-22s " "Swap Usage"
    _bar "$sw_pct" "$(_swap_label)"
    _blank

    _ok   "All memory reclamation procedures completed successfully."
    _hint "Sysctl tuning is active for the current session only."
    _hint "Run  sudo vacuum -I  to write permanent tuning to /etc/sysctl.d/99-vacuum.conf"
    _blank
    sleep 2
}

# =============================================================================
#  SECTION J -- AUTO-MONITOR MANAGER  (-M / --monitor)
# =============================================================================
do_monitor_manage() {
    _hdr
    _section "Auto-Monitor Watchdog -- Status and Management"

    local is_active=false
    local svc="/etc/systemd/system/vacuum-monitor.service"
    systemctl is-active --quiet vacuum-monitor 2>/dev/null && is_active=true || true

    local status_str=""
    $is_active && status_str="${BGRN}ACTIVE${RST}" || status_str="${BRED}INACTIVE${RST}"

    _thead "Parameter" "Current Value" "Description"
    _trow "Service Status"       "$status_str"                    "Live service state"
    _trow "Disk Trigger"         ">= ${THRESHOLD}%"              "Standard cleanup threshold"
    _trow "Aggressive Trigger"   ">= ${AGGRESSIVE_THRESHOLD}%"  "Deep clean threshold"
    _trow "CPU Load Trigger"     ">= ${LOAD_THRESHOLD}"          "1-min load average trigger"
    _trow "Check Interval"       "${MONITOR_INTERVAL} seconds"   "Metric polling frequency"
    _trow "Desktop Alerts"       "${NOTIFY}"                     "Desktop popup notifications"
    if $is_active; then
        local pid="" as=""
        pid=$(systemctl show vacuum-monitor --property=MainPID --value 2>/dev/null || echo "?")
        as=$(systemctl show vacuum-monitor --property=ActiveEnterTimestamp --value 2>/dev/null \
             | awk '{ print $1" "$2 }' || echo "?")
        _trow "Process PID"   "${pid:-?}"  "Running daemon PID"
        _trow "Active Since"  "${as:-?}"   "Service activation timestamp"
    fi
    _tfoot

    _section "Trigger Logic and Behaviour"
    printf "  ${DIM}Polls every ${BLD}${MONITOR_INTERVAL}s${RST}${DIM}. Triggers when any condition is met:\n"
    printf "    Disk >= ${BLD}${THRESHOLD}%%${RST}${DIM}               Standard cleanup\n"
    printf "    1-min load avg >= ${BLD}${LOAD_THRESHOLD}${RST}${DIM}      Standard cleanup\n"
    printf "    Disk >= ${BLD}${AGGRESSIVE_THRESHOLD}%%${RST}${DIM}          Aggressive cleanup\n"
    printf "  A 1-hour cooldown follows each trigger to prevent repeated runs.${RST}\n"
    _blank

    if [[ -f "$LOG_FILE" ]]; then
        local recent=""
        recent=$(grep "\[MONITOR\]" "$LOG_FILE" 2>/dev/null | tail -5 || true)
        if [[ -n "$recent" ]]; then
            _section "Recent Monitor Activity  (last 5 entries)"
            while IFS= read -r line; do printf "  ${GRY}%s${RST}\n" "$line"; done <<< "$recent"
        fi
    fi

    _section "Available Actions"
    if $is_active; then
        _thead "Option" "Action" "Effect"
        _trow "[1]" "Disable and Stop Monitor"   "Stops daemon, removes service unit"
        _trow "[2]" "Restart Monitor"            "Reloads config without downtime"
        _trow "[3]" "View Monitor Log"           "Last 20 monitor log entries"
        _trow "[0]" "Return to Main Menu"        "No changes applied"
        _tfoot
    else
        _thead "Option" "Action" "Effect"
        _trow "[1]" "Enable and Start Monitor"   "Installs service unit, starts daemon"
        _trow "[0]" "Return to Main Menu"        "No changes applied"
        _tfoot
    fi

    _blank
    _hint "After changing thresholds in Settings, use option [2] Restart to apply them."
    _blank
    read -rp "  Select action: " opt; _blank

    local self; self=$(realpath "$0")

    if $is_active; then
        case "$opt" in
            1)  _step "Stopping and disabling vacuum-monitor service"
                systemctl disable --now vacuum-monitor 2>/dev/null || true
                rm -f "$svc"; systemctl daemon-reload; _done
                _ok "Auto-Monitor has been DISABLED and stopped." ;;
            2)  _step "Restarting vacuum-monitor service"
                systemctl restart vacuum-monitor 2>/dev/null || true; _done
                _ok "Auto-Monitor restarted with current configuration." ;;
            3)  _blank
                grep "\[MONITOR\]" "$LOG_FILE" 2>/dev/null | tail -20 \
                    | while IFS= read -r line; do printf "  ${GRY}%s${RST}\n" "$line"; done \
                    || _warn "No monitor log entries found." ;;
            0)  return ;;
            *)  _err "Invalid selection." ;;
        esac
    else
        case "$opt" in
            1)  cat > "$svc" <<EOF
[Unit]
Description=Vacuum Auto-Monitor -- Disk and CPU Load Watchdog
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
                systemctl enable --now vacuum-monitor >/dev/null 2>&1 || true
                _ok "Auto-Monitor has been ENABLED and started."
                _kv "Disk Trigger"       ">= ${THRESHOLD}%"
                _kv "Aggressive Trigger" ">= ${AGGRESSIVE_THRESHOLD}%"
                _kv "CPU Load Trigger"   ">= ${LOAD_THRESHOLD}"
                _kv "Check Interval"     "${MONITOR_INTERVAL} seconds"
                _kv "Notifications"      "${NOTIFY}" ;;
            0)  return ;;
            *)  _err "Invalid selection." ;;
        esac
    fi
    _blank; sleep 2
}

# Monitor daemon -- invoked by systemd via --daemon
do_monitor_daemon() {
    _log "MONITOR" "Daemon started. Polling every ${MONITOR_INTERVAL}s."
    while true; do
        local p=0 load=0 trig=0
        read -r p _ < <(_stats) || true
        load=$(awk '{ print $1 }' /proc/loadavg 2>/dev/null || echo 0)
        trig=$(awk -v l="$load" -v t="$LOAD_THRESHOLD" 'BEGIN { print (l+0>=t+0)?1:0 }' 2>/dev/null || echo 0)
        if [[ "${p:-0}" -ge "${THRESHOLD:-85}" ]] || [[ "${trig:-0}" -eq 1 ]]; then
            _log "MONITOR" "Triggered -- Disk: ${p}%, Load: ${load}"
            _notify "Vacuum Auto-Monitor" \
                "Threshold exceeded (Disk: ${p}%, Load: ${load}). Running background cleanup."
            [[ "${p:-0}" -ge "${AGGRESSIVE_THRESHOLD:-95}" ]] && V_AGG=true || true
            V_MONITOR_MODE=true V_QUIET=true _cleanup
            local pa=0; read -r pa _ < <(_stats) || true
            _notify "Vacuum -- Cleanup Complete" \
                "Background cleanup finished. Disk: ${p}% to ${pa}%"
            sleep 3600
        else
            sleep "$MONITOR_INTERVAL"
        fi
    done
}

# =============================================================================
#  SECTION K -- SYSTEM DASHBOARD  (-s / --status)
# =============================================================================
do_status() {
    _hdr
    _section "System Resource Dashboard"

    local p=0 rm_pct=0 sw_pct=0 sw_total=0
    read -r p _ < <(_stats) || true
    rm_pct=$(_ram_pct);     [[ -z "$rm_pct"    ]] && rm_pct=0 || true
    sw_total=$(_swap_total_mb); [[ -z "$sw_total" ]] && sw_total=0 || true
    sw_pct=0; [[ $sw_total -gt 0 ]] && sw_pct=$(_swap_pct) || true

    local used_h free_h total_h
    used_h=$(_disk_used_human)
    free_h=$(_disk_free_human)
    total_h=$(_disk_total_human)

    printf "  %-22s " "Disk  /"
    _bar "${p:-0}" "${used_h} used / ${total_h} total  (${free_h} free)"
    _blank

    printf "  %-22s " "RAM"
    _bar "$rm_pct" "$(_ram_label)"
    _blank

    printf "  %-22s " "Swap"
    _bar "$sw_pct" "$(_swap_label)"
    _blank

    _section "System Information"
    _thead "Property" "Value" "Notes"
    _trow "Hostname"   "$(hostname 2>/dev/null || echo '?')"                                "Network identity"
    _trow "Kernel"     "$(uname -r 2>/dev/null || echo '?')"                               "Running kernel version"
    _trow "Uptime"     "$(uptime -p 2>/dev/null | sed 's/up //' || echo '?')"              "Time since last boot"
    _trow "Load Avg"   "$(awk '{ print $1" / "$2" / "$3 }' /proc/loadavg 2>/dev/null || echo '?')" "1m / 5m / 15m"
    _trow "CPU Cores"  "$(nproc 2>/dev/null || echo '?')"                                  "Logical processor count"
    _trow "Disk Free"  "$free_h"                                                            "Available on root fs"
    _trow "RAM Free"   "$(free -h 2>/dev/null | awk '/^Mem:/  { print $4 }' || echo '?')" "Immediately available"
    _trow "Swap Free"  "$(free -h 2>/dev/null | awk '/^Swap:/ { if ($2=="0B") print "N/A"; else print $4 }' || echo 'N/A')" "Swap headroom"
    _tfoot

    _section "Background Service Status"
    _thead "Service" "Status" "Detail"

    local sched_st="" sched_d=""
    if systemctl is-active --quiet vacuum.timer 2>/dev/null; then
        local next_left="" cal_str=""
        next_left=$(_next_run)
        cal_str=$(grep "OnCalendar=" /etc/systemd/system/vacuum.timer 2>/dev/null | cut -d'=' -f2 || echo "?")
        sched_st="${BGRN}Active${RST}"
        sched_d="Next run in: ${next_left}  Schedule: ${cal_str}"
    else
        sched_st="${GRY}Inactive${RST}"
        sched_d="No schedule configured"
    fi
    _trow "Timer Scheduler" "$sched_st" "$sched_d"

    local mon_st="" mon_d=""
    if systemctl is-active --quiet vacuum-monitor 2>/dev/null; then
        mon_st="${BGRN}Active${RST}"
        mon_d="Disk>=${THRESHOLD}%  Load>=${LOAD_THRESHOLD}  Every ${MONITOR_INTERVAL}s"
    else
        mon_st="${GRY}Inactive${RST}"
        mon_d="Use  sudo vacuum -M  to enable"
    fi
    _trow "Auto-Monitor" "$mon_st" "$mon_d"
    _tfoot

    _section "Recent Vacuum Activity"
    if [[ -f "$LOG_FILE" ]] && [[ -s "$LOG_FILE" ]]; then
        tail -6 "$LOG_FILE" | while IFS= read -r line; do printf "  ${GRY}%s${RST}\n" "$line"; done
    else
        _info "No log entries found. Run  sudo vacuum -r  to generate activity records."
    fi
    _blank
}

# =============================================================================
#  SECTION L -- CONFIGURATION EDITOR
# =============================================================================
_update_conf() {
    local key="$1" val="$2" conf="/etc/vacuum.conf"
    [[ -f "$conf" ]] || touch "$conf"
    if grep -q "^${key}=" "$conf" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$conf"
    else
        echo "${key}=${val}" >> "$conf"
    fi
    eval "${key}=${val}"
    _blank; _ok "Configuration saved -- ${BLD}${key}${RST} = ${BLD}${val}${RST}"; sleep 1.5
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
    _blank; _ok "All settings restored to factory defaults."; sleep 2
}

do_edit_limits() {
    while true; do
        _hdr
        _section "Configuration -- Thresholds, Limits and Behaviour"

        _thead "Option" "Current Value" "Description"
        _trow "[1] Standard Disk Threshold"   "${THRESHOLD}%"            "Monitor triggers standard cleanup above this"
        _trow "[2] Aggressive Disk Threshold" "${AGGRESSIVE_THRESHOLD}%" "Monitor triggers deep clean above this"
        _trow "[3] CPU Load Trigger"          "${LOAD_THRESHOLD}"        "1-min load avg that wakes the monitor"
        _trow "[4] Monitor Check Interval"    "${MONITOR_INTERVAL}s"     "How often the daemon polls metrics"
        _trow "[5] Desktop Notifications"     "${NOTIFY}"                "Popup alerts via notify-send"
        _trow "[6] Test Notification"         "--"                       "Send a test popup immediately"
        _trow "[7] Factory Reset"             "--"                       "Restore all settings to defaults"
        _trow "[0] Back"                      "--"                       "Return to main menu"
        _tfoot

        _blank
        _hint "Recommended: Standard 80-90%, Aggressive 92-97%, Load = number of CPU cores."
        _hint "Direct runs (-r / -a) always execute all phases regardless of threshold."
        _blank
        read -rp "  Select setting to edit (0-7): " opt; _blank

        case "$opt" in
            1)  read -rp "  New standard threshold (1-99, recommended 80-90): " v
                [[ "$v" =~ ^[0-9]+$ ]] && _update_conf "THRESHOLD" "$v" \
                    || { _err "Please enter a valid integer."; sleep 1; } ;;
            2)  read -rp "  New aggressive threshold (1-99, recommended 92-97): " v
                [[ "$v" =~ ^[0-9]+$ ]] && _update_conf "AGGRESSIVE_THRESHOLD" "$v" \
                    || { _err "Please enter a valid integer."; sleep 1; } ;;
            3)  read -rp "  New CPU load threshold (e.g. 4.0 for a 4-core system): " v
                _update_conf "LOAD_THRESHOLD" "$v" ;;
            4)  read -rp "  New check interval in seconds (minimum recommended: 30): " v
                [[ "$v" =~ ^[0-9]+$ ]] && _update_conf "MONITOR_INTERVAL" "$v" \
                    || { _err "Please enter a valid integer."; sleep 1; } ;;
            5)  read -rp "  Enable desktop notifications? (true / false): " v
                [[ "$v" == "true" || "$v" == "false" ]] && _update_conf "NOTIFY" "$v" \
                    || { _err "Value must be exactly 'true' or 'false'."; sleep 1; } ;;
            6)  _blank; _step "Dispatching test desktop notification"
                _notify "Vacuum -- Test" "Desktop notifications are configured and operational." \
                    && _done || { _blank; _err "Failed. Ensure notify-send is installed."; sleep 2; }
                sleep 1 ;;
            7)  _reset_conf ;;
            0)  if systemctl is-active --quiet vacuum-monitor 2>/dev/null; then
                    _blank; _step "Restarting Auto-Monitor to apply configuration"
                    systemctl restart vacuum-monitor 2>/dev/null || true; _done; sleep 1
                fi; return ;;
            *)  _err "Invalid selection. Enter a number between 0 and 7."; sleep 1 ;;
        esac
    done
}

# =============================================================================
#  SECTION M -- TIME-BASED SCHEDULER
# =============================================================================
do_schedule_menu() {
    _hdr
    _section "Time-Based Scheduler -- Automated Recurring Cleanup"

    local is_timer=false
    systemctl is-active --quiet vacuum.timer 2>/dev/null && is_timer=true || true

    _thead "Property" "Value" "Notes"
    if $is_timer; then
        local cal="" next_left=""
        cal=$(grep "OnCalendar=" /etc/systemd/system/vacuum.timer 2>/dev/null | cut -d'=' -f2 || echo "?")
        next_left=$(_next_run)
        _trow "Scheduler Status"  "${BGRN}Active${RST}"   "Timer is currently running"
        _trow "Schedule"          "$cal"                  "systemd OnCalendar expression"
        _trow "Next Execution"    "$next_left"            "Time remaining until next run"
    else
        _trow "Scheduler Status"  "${GRY}Inactive${RST}"  "No automated schedule configured"
        _trow "Schedule"          "--"                    "Not set"
        _trow "Next Execution"    "--"                    "Not applicable"
    fi
    _tfoot

    _blank
    _thead "Option" "Schedule" "Recommended Use Case"
    _trow "[1]" "Every 30 minutes"       "High-traffic developer workstations"
    _trow "[2]" "Every 1 hour"           "Active desktops and daily-use systems"
    _trow "[3]" "Daily at midnight"      "General servers and workstations"
    _trow "[4]" "Weekly Sunday 03:00"    "Low-usage or always-on servers"
    _trow "[5]" "Custom expression"      "Advanced: any valid OnCalendar string"
    _trow "[6]" "Remove scheduler"       "Fully disable all timer-based automation"
    _trow "[0]" "Return to main menu"    "No changes applied"
    _tfoot

    _blank
    _hint "The scheduler runs  sudo vacuum -r -q  (standard cleanup, silent) as a systemd oneshot."
    _blank
    read -rp "  Select schedule option (0-6): " opt; _blank

    case "$opt" in
        6)  systemctl disable --now vacuum.timer 2>/dev/null || true
            rm -f /etc/systemd/system/vacuum.service /etc/systemd/system/vacuum.timer 2>/dev/null || true
            systemctl daemon-reload
            _ok "Scheduler has been removed and fully disabled."; sleep 2; return ;;
        0|"") return ;;
    esac

    local cal="daily"
    case "$opt" in
        1) cal="*:0/30"             ;;
        2) cal="hourly"             ;;
        3) cal="daily"              ;;
        4) cal="Sun *-*-* 03:00:00" ;;
        5) read -rp "  Enter systemd OnCalendar expression (e.g. *-*-* 04:00:00): " cal ;;
        *) _err "Invalid selection."; sleep 1; return ;;
    esac

    local self; self=$(realpath "$0")
    cat > /etc/systemd/system/vacuum.service <<EOF
[Unit]
Description=Vacuum -- Automated Disk and Memory Cleanup
[Service]
Type=oneshot
ExecStart=$self -r -q
EOF
    cat > /etc/systemd/system/vacuum.timer <<EOF
[Unit]
Description=Vacuum Cleanup Timer
Requires=vacuum.service
[Timer]
OnCalendar=$cal
Persistent=true
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now vacuum.timer >/dev/null 2>&1 || true
    _ok "Automated scheduler enabled successfully."
    _kv "OnCalendar Expression"  "$cal"
    _kv "Execution Mode"         "Standard cleanup (-r) with silent output (-q)"
    sleep 2
}

# =============================================================================
#  SECTION N -- INTERACTIVE MAIN MENU
# =============================================================================
do_interactive() {
    while true; do
        _hdr
        _section "Main Menu -- Select an Operation"

        _thead "Option" "Operation" "Description"
        _trow "[1]  Standard Cleanup"       "" "Journals, packages, caches, temp, RAM, swap -- always runs"
        _trow "[2]  Aggressive Deep Clean"  "" "Adds: old kernels, browser data, all build tool caches"
        _trow "[3]  Simulation Dry-Run"     "" "Preview all planned actions without any file changes"
        _trow "[4]  Memory Optimizer"       "" "Full RAM, swap and kernel memory reclamation only"
        _trow "[5]  System Dashboard"       "" "Live disk, RAM, swap, service status and recent logs"
        _trow "[6]  Configure Settings"     "" "Edit monitor thresholds, intervals and notifications"
        _trow "[7]  Scheduler Manager"      "" "Set up or remove time-based automated cleanup"
        _trow "[8]  Auto-Monitor Watchdog"  "" "View status -- enable or disable background daemon"
        _trow "[0]  Exit"                   "" "Quit Vacuum"
        _tfoot

        _blank
        _hint "Standard Cleanup always runs all 10 phases including full memory reclamation."
        _hint "Aggressive Clean is recommended monthly or when disk usage exceeds 90%."
        _blank
        read -rp "  Enter selection (0-8): " opt; _blank

        case "$opt" in
            1)  _root; _cleanup;             _blank; read -rp "  Press Enter to continue ..." _ ;;
            2)  _root; V_AGG=true; _cleanup; _blank; read -rp "  Press Enter to continue ..." _ ;;
            3)  _root; V_DRY=true; _cleanup; _blank; read -rp "  Press Enter to continue ..." _ ;;
            4)  _root; do_ram_optimizer ;;
            5)  do_status;                   _blank; read -rp "  Press Enter to continue ..." _ ;;
            6)  _root; do_edit_limits ;;
            7)  _root; do_schedule_menu ;;
            8)  _root; do_monitor_manage ;;
            0)  _blank; exit 0 ;;
            *)  _err "Invalid selection. Enter a number between 0 and 8."; sleep 1 ;;
        esac
    done
}

# =============================================================================
#  SECTION O -- HELP PAGE
# =============================================================================
do_help() {
    _hdr
    _section "Command-Line Flag Reference"
    _thead "Short Flag" "Long Form" "Description"
    _trow "-i"  "--interactive"  "Launch the full interactive menu system"
    _trow "-r"  "--run"          "Standard cleanup -- all phases, always executes"
    _trow "-a"  "--aggressive"   "Deep clean: kernels, all caches, container volumes"
    _trow "-d"  "--dry-run"      "Simulate all actions without deleting any files"
    _trow "-m"  "--ram"          "Standalone memory and swap optimizer only"
    _trow "-q"  "--quiet"        "Suppress all UI output (suitable for cron and systemd)"
    _trow "-s"  "--status"       "Display live system resource dashboard"
    _trow "-S"  "--schedule"     "Open the time-based scheduler manager"
    _trow "-M"  "--monitor"      "Auto-Monitor: view status, enable or disable daemon"
    _trow "-I"  "--install"      "Install config, completion and permanent sysctl tuning"
    _trow "-h"  "--help"         "Display this reference page"
    _tfoot

    _section "Usage Examples"
    _thead "Command" "What It Does" "Best Used For"
    _trow "sudo vacuum -r"     "Standard cleanup (all phases)"   "Weekly routine maintenance"
    _trow "sudo vacuum -a"     "Aggressive deep clean"           "Monthly or disk above 90%"
    _trow "sudo vacuum -a -q"  "Silent aggressive cleanup"       "Cron and automation tasks"
    _trow "sudo vacuum -d"     "Dry-run simulation"              "Preview before committing"
    _trow "sudo vacuum -m"     "Memory optimizer only"           "Slow system or high RAM use"
    _trow "sudo vacuum -M"     "Monitor status and control"      "Enable or disable watchdog"
    _trow "sudo vacuum -s"     "Resource dashboard"              "Quick system health check"
    _trow "sudo vacuum -i"     "Interactive interface"           "Manual and first-time use"
    _tfoot

    _blank
    _hint "Direct runs (-r / -a) always execute all phases regardless of disk threshold."
    _hint "Thresholds only apply to the Auto-Monitor background daemon."
    _hint "Swap flush is skipped automatically when RAM exceeds 75% to prevent OOM events."
    _blank
}

# =============================================================================
#  SECTION P -- INSTALLATION
# =============================================================================
do_install() {
    _hdr; _root
    _section "Installation -- Directories, Configuration and Shell Integration"

    _step "Creating report directory and log file"
    mkdir -p "$REPORT_DIR" /etc/bash_completion.d
    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"
    chmod 750 "$REPORT_DIR"
    _done

    _step "Installing bash tab-completion definitions"
    cat > /etc/bash_completion.d/vacuum <<'EOF'
complete -W "-i --interactive -r --run -a --aggressive -d --dry-run -m --ram -q --quiet -s --status -S --schedule -M --monitor -I --install -h --help" vacuum
EOF
    _done

    _step "Writing /etc/vacuum.conf  (skipped if already present)"
    if [[ ! -f /etc/vacuum.conf ]]; then
        cat > /etc/vacuum.conf <<EOF
# Vacuum -- Main Configuration
# Edit values below or use:  sudo vacuum -i  then option 6

THRESHOLD=$THRESHOLD
AGGRESSIVE_THRESHOLD=$AGGRESSIVE_THRESHOLD
LOAD_THRESHOLD=$LOAD_THRESHOLD
MONITOR_INTERVAL=$MONITOR_INTERVAL
NOTIFY=$NOTIFY
EOF
        _done
    else
        printf " ${GRY}Already exists -- preserved unchanged${RST}\n"
    fi

    _step "Writing permanent sysctl tuning to /etc/sysctl.d/99-vacuum.conf"
    cat > /etc/sysctl.d/99-vacuum.conf <<'EOF'
# Vacuum -- Permanent Kernel Memory Tuning
# Applied at every system boot.
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
EOF
    _done

    _section "Installation Summary"
    _thead "Component" "Location" "Purpose"
    _trow "Report Directory"  "$REPORT_DIR"                    "Per-session cleanup reports (last 20)"
    _trow "Log File"          "$LOG_FILE"                      "Persistent event and audit log"
    _trow "Configuration"     "/etc/vacuum.conf"               "User-editable runtime settings"
    _trow "sysctl Tuning"     "/etc/sysctl.d/99-vacuum.conf"   "Permanent kernel memory parameters"
    _trow "Bash Completion"   "/etc/bash_completion.d/vacuum"  "Tab-completion for all CLI flags"
    _tfoot

    _blank
    _ok  "${BLD}Vacuum installed successfully.${RST}"
    _hint "Interactive menu:          sudo vacuum -i"
    _hint "Enable background monitor: sudo vacuum -M"
    _hint "Run standard cleanup now:  sudo vacuum -r"
    _blank
}

# =============================================================================
#  SECTION Q -- CLI ROUTER
# =============================================================================
[[ $# -eq 0 ]] && { do_help; exit 0; } || true

ACTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--interactive) ACTION="interactive" ;;
        -r|--run)         ACTION="run" ;;
        -a|--aggressive)  ACTION="agg" ;;
        -d|--dry-run)     V_DRY=true; ACTION="${ACTION:-run}" ;;
        -m|--ram)         ACTION="ram" ;;
        -q|--quiet)       V_QUIET=true ;;
        -S|--schedule)    ACTION="schedule" ;;
        -M|--monitor)     ACTION="monitor" ;;
        --daemon)         ACTION="daemon" ;;
        -s|--status)      ACTION="status" ;;
        -I|--install)     ACTION="install" ;;
        -h|--help)        ACTION="help" ;;
        -*) _err "Unrecognised flag: $1"; _blank; do_help; exit 1 ;;
    esac
    shift
done

[[ -n "$V_QUIET" && -z "$ACTION" ]] && ACTION="run" || true

case "$ACTION" in
    interactive) do_interactive ;;
    run)         _root; _cleanup ;;
    agg)         _root; V_AGG=true; _cleanup ;;
    ram)         _root; do_ram_optimizer ;;
    schedule)    _root; do_schedule_menu ;;
    monitor)     _root; do_monitor_manage ;;
    daemon)      _root; do_monitor_daemon ;;
    status)      do_status ;;
    install)     do_install ;;
    help|*)      do_help ;;
esac
