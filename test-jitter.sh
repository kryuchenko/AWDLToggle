#!/bin/bash

# Jitter test: AWDL on vs off
# Usage: ./test-jitter.sh [-d|--debug] [host] [count]

DEBUG=0
if [[ "$1" == "-d" || "$1" == "--debug" ]]; then
    DEBUG=1
    shift
fi

HOST="${1:-8.8.8.8}"
COUNT="${2:-100}"
LOGFILE="jitter-test-$(date +%Y%m%d-%H%M%S).log"

log() {
    if [[ $DEBUG -eq 1 ]]; then
        echo "[DEBUG] $1" | tee -a "$LOGFILE"
    fi
}

log_raw() {
    if [[ $DEBUG -eq 1 ]]; then
        echo "$1" >> "$LOGFILE"
    fi
}

echo "🧪 AWDL Jitter Test"
echo "   Host: $HOST"
echo "   Samples: $COUNT"
if [[ $DEBUG -eq 1 ]]; then
    echo "   Debug: ON (logging to $LOGFILE)"
    log "=== AWDL Jitter Test ==="
    log "Host: $HOST"
    log "Samples: $COUNT"
    log "Date: $(date)"
    log "macOS: $(sw_vers -productVersion)"
    log "Hardware: $(sysctl -n hw.model)"
    log ""
fi

# Check sudo status
if sudo -n true 2>/dev/null; then
    echo "   Sudo: cached (no password needed)"
elif [ -f /etc/sudoers.d/awdltoggle ]; then
    echo "   Sudo: NOPASSWD rule active"
else
    echo "   Sudo: will ask for password"
    sudo -v
fi
echo ""

# Function to run ping and extract times
run_ping() {
    ping -c "$COUNT" -i 0.2 "$HOST" 2>/dev/null | grep "time=" | sed 's/.*time=\([0-9.]*\).*/\1/'
}

# Function to calculate stats
calc_stats() {
    sort -n | awk '
    {
        sum += $1
        values[NR] = $1
    }
    END {
        avg = sum / NR

        # Median
        if (NR % 2 == 1) {
            median = values[(NR + 1) / 2]
        } else {
            median = (values[NR / 2] + values[NR / 2 + 1]) / 2
        }

        # Min/Max
        min = values[1]
        max = values[NR]

        # Jitter (std dev)
        for (i = 1; i <= NR; i++) {
            sumsq += (values[i] - avg) ^ 2
        }
        stddev = sqrt(sumsq / NR)

        printf "%.2f %.2f %.2f %.2f %.2f", avg, median, min, max, stddev
    }'
}

# Test with AWDL OFF first (cleaner baseline)
echo "📴 Testing with AWDL OFF..."
log "=== AWDL OFF Test ==="
sudo ifconfig awdl0 down
log "ifconfig awdl0 down executed"
sleep 2

log "Starting ping..."
RESULTS_OFF=$(run_ping)
log "Raw ping results (AWDL OFF):"
log_raw "$RESULTS_OFF"
STATS_OFF=$(echo "$RESULTS_OFF" | calc_stats)
read AVG_OFF MED_OFF MIN_OFF MAX_OFF JITTER_OFF <<< "$STATS_OFF"
log "Stats: avg=$AVG_OFF med=$MED_OFF min=$MIN_OFF max=$MAX_OFF jitter=$JITTER_OFF"

echo "   Done."
echo ""

# Test with AWDL ON
echo "📶 Testing with AWDL ON..."
log "=== AWDL ON Test ==="
sudo ifconfig awdl0 up
log "ifconfig awdl0 up executed"
sleep 1

# Wake up AWDL by triggering AirDrop browse
echo "   Waking up AWDL (triggering AirDrop)..."
log "Triggering AirDrop discovery..."
dns-sd -B _airdrop._tcp local. > /dev/null 2>&1 &
DNS_PID=$!
sleep 5
kill $DNS_PID 2>/dev/null
log "AirDrop discovery done"

log "Starting ping..."
RESULTS_ON=$(run_ping)
log "Raw ping results (AWDL ON):"
log_raw "$RESULTS_ON"
STATS_ON=$(echo "$RESULTS_ON" | calc_stats)
read AVG_ON MED_ON MIN_ON MAX_ON JITTER_ON <<< "$STATS_ON"
log "Stats: avg=$AVG_ON med=$MED_ON min=$MIN_ON max=$MAX_ON jitter=$JITTER_ON"

echo "   Done."
echo ""

# Turn AWDL back off
sudo ifconfig awdl0 down
log "Test complete, AWDL turned off"

# Results
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 RESULTS (ping to $HOST, $COUNT samples)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
printf "%-20s %12s %12s\n" "" "AWDL OFF" "AWDL ON"
echo "──────────────────────────────────────────────"
printf "%-20s %10.2f ms %10.2f ms\n" "Average" "$AVG_OFF" "$AVG_ON"
printf "%-20s %10.2f ms %10.2f ms\n" "Median" "$MED_OFF" "$MED_ON"
printf "%-20s %10.2f ms %10.2f ms\n" "Min" "$MIN_OFF" "$MIN_ON"
printf "%-20s %10.2f ms %10.2f ms\n" "Max" "$MAX_OFF" "$MAX_ON"
printf "%-20s %10.2f ms %10.2f ms\n" "Jitter (σ)" "$JITTER_OFF" "$JITTER_ON"
echo ""

# Improvement
if (( $(echo "$JITTER_ON > 0" | bc -l) )); then
    IMPROVEMENT=$(echo "$JITTER_ON $JITTER_OFF" | awk '{printf "%.0f", (($1 - $2) / $1) * 100}')
    echo "📈 Jitter reduction with AWDL OFF: ${IMPROVEMENT}%"
else
    echo "📈 Could not calculate improvement"
fi
echo ""

if [[ $DEBUG -eq 1 ]]; then
    log ""
    log "=== Final Results ==="
    log "AWDL OFF: avg=$AVG_OFF med=$MED_OFF min=$MIN_OFF max=$MAX_OFF jitter=$JITTER_OFF"
    log "AWDL ON:  avg=$AVG_ON med=$MED_ON min=$MIN_ON max=$MAX_ON jitter=$JITTER_ON"
    log "Improvement: ${IMPROVEMENT}%"
    echo "📝 Debug log saved to: $LOGFILE"
fi
