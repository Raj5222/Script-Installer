#!/usr/bin/env bash

# --- Configuration & Setup ---
export CONFIG_URL="https://raw.githubusercontent.com/raj5222/Script-Installer/main/config.json"
TMP_DIR="/tmp/pro-installer-$$"
export REG="$TMP_DIR/r.tmp"

# --- Colors & UI Elements ---
C_GRN='\033[1;32m' C_RED='\033[1;31m' C_CYN='\033[1;36m' C_WHT='\033[1;37m' C_YLW='\033[1;33m' C_BLU='\033[1;34m' GRY='\033[0;90m' NC='\033[0m'
T="${C_GRN}✔${NC}" X="${C_RED}✖${NC}" I="${C_BLU}ℹ${NC}"

# --- Core Functions ---
cleanup() { tput cnorm; stty echo; rm -rf "$TMP_DIR" 2>/dev/null; }
trap cleanup EXIT
trap 'echo -e "\n\n $X ${C_RED}Aborted by user.${NC}\033[K\n"; exit 1' INT TERM
tput civis; stty -echo; mkdir -p "$TMP_DIR"

banner() {
    clear; echo -e "${C_CYN}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\n┃                     ${C_WHT}🚀 SCRIPTS INSTALLER${NC}                   ${C_CYN}┃\n┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}\n"
}

run_task() {
    eval "$2" >/dev/null 2>&1 & pid=$!; i=0
    frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    while kill -0 $pid 2>/dev/null; do
        printf "\r ${C_CYN}%s${NC} ${C_WHT}%s${NC}\033[K" "${frames[i]}" "$1"
        i=$(( (i + 1) % 10 )); sleep 0.05
    done
    wait $pid && printf "\r $T ${C_WHT}%s ${GRY}(Done)${NC}\033[K\n" "$1" || { printf "\r $X ${C_RED}Failed: %s${NC}\033[K\n" "$1"; exit 1; }
}

# --- CLI Parsing ---
AUTO=false; CLI_TOOLS=""
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -a|--all) AUTO=true ;;
        -h|--help) echo "Usage: $0 [-a] [TOOLS...]"; exit 0 ;;
        *[0-9]*) CLI_TOOLS="$CLI_TOOLS $1" ;;
        *) echo -e "$X ${C_RED}Invalid: $1${NC}"; exit 1 ;;
    esac; shift
done

# --- Initialization & Validation ---
banner
echo -e "${C_WHT} [1/4] System Validation${NC}"
command -v python3 >/dev/null || { echo -e " $X ${C_RED}Python3 missing.${NC}"; exit 1; }
command -v apt-get >/dev/null || { echo -e " $X ${C_RED}Requires apt-get OS.${NC}"; exit 1; }

sudo -n true 2>/dev/null || { echo -ne " $I ${C_YLW}Sudo required...${NC}\n"; tput cnorm; stty echo; sudo -v || exit 1; tput civis; stty -echo; echo -e "\r\033[K $T ${C_GRN}Privileges granted.${NC}"; }

# Bulletproof Python fetcher
cat << 'EOF' > "$TMP_DIR/f.py"
import json, urllib.request, sys, os
try:
    r = urllib.request.urlopen(os.environ['CONFIG_URL'], timeout=10)
    d = json.loads(r.read()).get('scripts', [])
    with open(os.environ['REG'], 'w') as f:
        for i, s in enumerate(d):
            if all(k in s for k in ('name','url','install_path')):
                f.write(f"{i+1}|{s['name']}|{s['url']}|{s['install_path']}|{','.join(s.get('dependencies',[]))}|{s.get('description','')}\n")
except: sys.exit(1)
EOF

run_task "Fetching registry" "python3 '$TMP_DIR/f.py'" || exit 1
mapfile -t SCRIPTS < "$REG"
TOT=${#SCRIPTS[@]}; OPT_ALL=$((TOT + 1))

# --- Selection Menu ---
banner; echo -e "${C_WHT} [2/4] Tool Selection${NC}"
if [ "$AUTO" = true ]; then SEL=$(seq 1 "$TOT")
elif [ -n "$CLI_TOOLS" ]; then SEL=$(grep -oE '[0-9]+' <<< "$CLI_TOOLS" | sort -nu)
else
    echo -e "${GRY} (Tip: Use numbers separated by space, or 'q' to exit)${NC}\n"
    for line in "${SCRIPTS[@]}"; do
        IFS='|' read -r i n u d p desc <<< "$line"
        [ -f "$d" ] && st="[  Installed  ]" c="$C_GRN" || { st="[Not Installed]"; c="$GRY"; }
        printf "  ${C_CYN}%2d)${NC} ${C_WHT}%-18s${NC} %b%-15s${NC}  ${GRY}%s${NC}\n" "$i" "$n" "$c" "$st" "$desc"
    done
    printf "\n  ${C_CYN}%2d)${NC} ${C_WHT}Install/Update ALL Tools${NC}\n" "$OPT_ALL"

    tput cnorm; stty echo
    while true; do
        read -p $'\n Selection » ' INP
        [[ "${INP,,}" =~ ^(q|quit|exit)$ ]] && { echo -e " $I ${C_BLU}Exiting.${NC}"; exit 0; }
        [[ "$INP" == *"$OPT_ALL"* ]] && { SEL=$(seq 1 "$TOT"); break; }
        SEL=$(grep -oE '[0-9]+' <<< "$INP" | sort -nu)
        [ -z "$SEL" ] && { echo -e " $X ${C_RED}Invalid input.${NC}"; continue; }
        V=0; for x in $SEL; do [ "$x" -ge 1 ] && [ "$x" -le "$TOT" ] && ((V++)); done
        [ "$V" -gt 0 ] && break || echo -e " $X ${C_RED}No valid tools selected. Try again.${NC}"
    done
    tput civis; stty -echo
fi

# --- Dependency Resolution ---
echo -e "\n${C_WHT} [3/4] Dependency Resolution${NC}"
MISSING=""
for idx in $SEL; do
    [ "$idx" -lt 1 ] || [ "$idx" -gt "$TOT" ] && continue
    IFS='|' read -r _ n u d deps _ <<< "${SCRIPTS[$((idx-1))]}"
    PAYLOADS+=("$n|$u|$d")
    for dep in ${deps//,/ }; do command -v "$dep" >/dev/null || MISSING="$MISSING $dep"; done
done

[ ${#PAYLOADS[@]} -eq 0 ] && { echo -e "\n $X ${C_RED}No tools to process.${NC}"; exit 1; }

MISSING=$(echo "$MISSING" | xargs -n1 2>/dev/null | sort -u | xargs)
[ -n "$MISSING" ] && run_task "Installing deps: $MISSING" "sudo apt-get install -y $MISSING" || echo -e " $T ${C_GRN}Dependencies met${NC}"

# --- Smart Installation ---
echo -e "\n${C_WHT} [4/4] Processing Installs & Updates${NC}"
sudo -v; REPORT=""
for p in "${PAYLOADS[@]}"; do
    IFS='|' read -r n u d <<< "$p"; tmp="$TMP_DIR/$n.sh"
    run_task "Fetching: $n" "curl -fsSL '$u' -o '$tmp'"
    
    if [ -f "$d" ]; then
        if cmp -s "$tmp" "$d"; then
            echo -e "  $I ${C_BLU}Skipping $n: Up-to-date${NC}"
            REPORT+="  \033[1;34mℹ\033[0m ${C_WHT}$n${NC} ${GRY}(Up-to-date)${NC}\n"
        else
            run_task "Updating: $n" "sudo install -D -m 755 '$tmp' '$d'"
            REPORT+="  \033[1;33m➜\033[0m ${C_WHT}$n${NC} ${GRY}(Updated)${NC}\n"
        fi
    else
        run_task "Installing: $n" "sudo install -D -m 755 '$tmp' '$d'"
        REPORT+="  ${C_GRN}➜${NC} ${C_WHT}$n${NC} ${GRY}(Installed)${NC}\n"
    fi
done

# --- Completion ---
echo -e "\n${C_GRN}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\n┃                ${C_WHT}🎉 INSTALLATION COMPLETED!${NC}                  ${C_GRN}┃\n┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
echo -e "\n${C_WHT} Status Report:${NC}\n$REPORT"
