#!/bin/bash

set -m 
RAW_TARGET="${1:-.}"
TARGET_DIR=$(realpath "$RAW_TARGET" 2>/dev/null || (cd "$RAW_TARGET" && pwd))

if [ ! -d "$TARGET_DIR" ]; then
    echo "❌ Error: Directory '$RAW_TARGET' does not exist."
    exit 1
fi

RESULTS_FILE="/tmp/scan_$(date +%s).tmp"
REPORT_FILE="$TARGET_DIR/architecture_health_report.txt"

# 2. SIGNAL HANDLING
cleanup() {
    if [ -f "$RESULTS_FILE" ]; then
        echo -e "\n\n🛑 STOPPED. Cleaning up..."
        kill -9 -$PID 2>/dev/null
        rm -f "$RESULTS_FILE"
    fi
    exit 1
}
trap cleanup SIGINT SIGTERM

# ==============================================================================
# 3. CORE DETECTION ENGINE
# ==============================================================================
scan_pattern() {
    local REGEX=$1
    local CATEGORY=$2
    local TITLE=$3
    local SEVERITY=$4
    local RANK=$5

    grep -rnI --include=\*.{js,jsx,ts,tsx} \
        --exclude-dir={node_modules,dist,build,.git,coverage,vendor,bin,obj,.next,test,tests,__tests__} \
        -E "$REGEX" "$TARGET_DIR" | \
        grep -vE ":[0-9]+:[[:space:]]*(//|/\*|\*)" | \
        while read -r line; do
            FILE_PATH=$(echo "$line" | cut -d: -f1)
            LINE_NUM=$(echo "$line" | cut -d: -f2)
            CODE_SNIPPET=$(echo "$line" | cut -d: -f3-)
            REL_PATH="${FILE_PATH#$TARGET_DIR/}"
            CLEAN_CODE=$(echo "$CODE_SNIPPET" | sed -e 's/^[[:space:]]*//')

            # --- SMART REMEDIATION LOGIC ---
            case "$TITLE" in
                "SYNC BLOCKER")      FIX=$(echo "$CLEAN_CODE" | sed -E 's/fs\.read.*Sync/await fs.promises.readFile/') ;;
                "UNSAFE DELETE")     FIX=$(echo "$CLEAN_CODE" | sed -E 's/delete[[:space:]]+([^;]+);?/\1 = undefined;/') ;;
                "MUTATION RISK")     FIX="const copy = structuredClone(item); // Don't mutate the original!" ;;
                "GLOBAL LEAK")       FIX="// Encapsulate this in a class or module scope." ;;
                "TIMER LEAK")        FIX="const ref = $CLEAN_CODE // Must call clearInterval(ref)" ;;
                "MEMORY SPIKE")      FIX="// Use Streams or limit the Array allocation size." ;;
                "UNSAFE PARSE")      FIX="try { $CLEAN_CODE } catch (e) { ... }" ;;
                *)                   FIX="(Manual refactor required)" ;;
            esac

            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$RANK" "$SEVERITY" "$CATEGORY" "$TITLE" "$REL_PATH:$LINE_NUM" "$CLEAN_CODE" "$FIX" >> "$RESULTS_FILE"
        done
}

# ==============================================================================
# 4. ARCHITECTURE DEFINITIONS
# ==============================================================================
run_scan() {
    # 🔴 CATEGORY: MEMORY & LEAKS (RANK 1)
    scan_pattern "setInterval\(" "MEMORY_LEAK" "TIMER LEAK" "HIGH" 1
    scan_pattern "addEventListener\(" "MEMORY_LEAK" "EVENT LEAK" "HIGH" 1
    scan_pattern "new Promise\(\(\) =>" "MEMORY_LEAK" "HANGING PROMISE" "HIGH" 1

    # 🟠 CATEGORY: PERFORMANCE & SPIKES (RANK 2)
    scan_pattern "fs\.read.*Sync" "PERFORMANCE" "SYNC BLOCKER" "HIGH" 2
    scan_pattern "JSON\.parse\(JSON\.stringify" "PERFORMANCE" "CLONE SPIKE" "MED" 2
    scan_pattern "new Array\([0-9]{5,}\)" "PERFORMANCE" "MEMORY SPIKE" "MED" 2
    scan_pattern "JSON\.parse\(" "PERFORMANCE" "UNSAFE PARSE" "MED" 2

    # 🟡 CATEGORY: MUTATION & STATE (RANK 3)
    scan_pattern "(\.push\(|\.splice\(|\.pop\(|\.shift\()" "MUTATION" "STATE MUTATION" "MED" 3
    scan_pattern "^export (let|var)" "MUTATION" "MUTABLE EXPORT" "MED" 3
    scan_pattern "(window\.|global\.)" "STATE" "GLOBAL LEAK" "MED" 3

    # 🔵 CATEGORY: ENGINE OPTIMIZATION (RANK 4)
    scan_pattern "delete [a-zA-Z0-9_]+\." "OPTIMIZATION" "UNSAFE DELETE" "LOW" 4
}

# ==============================================================================
# 5. EXECUTION & UI
# ==============================================================================
clear
echo "================================================================================="
echo "🕵️  FORENSIC ARCHITECT | $TARGET_DIR"
echo "================================================================================="

run_scan &
PID=$!

sp="/-\|"
while kill -0 $PID 2>/dev/null; do
    printf "\r🔍 Analyzing Architecture... [${sp:i++%${#sp}:1}]"
    sleep 0.1
done
printf "\r✅ Analysis Complete!                 \n"

# ==============================================================================
# 6. REPORT GENERATION
# ==============================================================================
if [ ! -s "$RESULTS_FILE" ]; then
    echo "✨ Architecture is perfect."
    rm -f "$RESULTS_FILE"
    exit 0
fi

{
    echo "================================================================================"
    echo "🏗️  ARCHITECTURE & MEMORY AUDIT REPORT"
    echo "📂 TARGET: $TARGET_DIR"
    echo "📅 DATE:   $(date)"
    echo "================================================================================"
    
    PREV_CAT=""
    PREV_TITLE=""
    
    sort -t$'\t' -k1,1n "$RESULTS_FILE" | while IFS=$'\t' read -r RANK SEV CAT TITLE LOC CODE FIX; do
        if [ "$CAT" != "$PREV_CAT" ]; then
            echo -e "\n\n"
            echo "════════════════════════════════════════════════════════════════════════════════"
            echo " 📂 CATEGORY: $CAT [$SEV]"
            echo "════════════════════════════════════════════════════════════════════════════════"
            PREV_CAT="$CAT"
        fi

        if [ "$TITLE" != "$PREV_TITLE" ]; then
            echo -e "\n👉 ISSUE: $TITLE"
            echo "--------------------------------------------------------------------------------"
            PREV_TITLE="$TITLE"
        fi

        echo "📍 $LOC"
        echo "   ❌ BAD: $CODE"
        echo "   ✅ FIX: $FIX"
    done
} > "$REPORT_FILE"

echo "📄 Report: $REPORT_FILE"
echo "💡 Use Arrows to scroll. Press 'q' to exit."
sleep 1

less -RS "$REPORT_FILE"
rm -f "$RESULTS_FILE"
