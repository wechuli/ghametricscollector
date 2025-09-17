#!/bin/bash

################################################################################
# System Monitor with GitHub Context - JSON Array Output
# Author: System Admin
# Date: 2025-09-17
# Description: Monitors system and appends to JSON array file
################################################################################

set -euo pipefail

# Default values
OUTPUT_FILE="/tmp/system_monitor.json"
MODE="minimal"
USER_LOGIN=""
GITHUB_REPOS=""
UPDATE_INTERVAL=1  # Default 1 minute
MAX_ENTRIES=1440    # Max entries to keep (1440 = 24 hours at 1 min interval)

################################################################################
# Parse command line arguments
################################################################################

show_help() {
    cat <<EOF
System Monitor with GitHub Context - JSON Array Output

Usage: $0 [OPTIONS]

OPTIONS:
    -o, --output FILE      Output file path (default: /tmp/system_monitor_array.json)
    -m, --mode MODE        Monitor mode: minimal, extended, full (default: minimal)
    -u, --user USER        GitHub username for context
    -r, --repos REPOS      Comma-separated list of repos (owner/repo format)
    -i, --interval MINS    Update interval in minutes (default: 1)
    --max-entries NUM      Maximum entries to keep in array (default: 1440)
    -h, --help            Show this help message

EXAMPLES:
    # Default: 1 minute interval
    $0 -u wechuli -r "wechuli/kubecosmos,arctestingorg/k8smodebug" -o ./monitor.json

    # Update every 5 minutes
    $0 -u wechuli -r "wechuli/kubecosmos" -i 5 -o ./monitor.json

    # Extended mode with 2 minute interval
    $0 -m extended -i 2 -u wechuli -r "wechuli/kubecosmos" -o ./monitor.json

EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -m|--mode)
            MODE="$2"
            shift 2
            ;;
        -u|--user)
            USER_LOGIN="$2"
            shift 2
            ;;
        -r|--repos)
            GITHUB_REPOS="$2"
            shift 2
            ;;
        -i|--interval)
            UPDATE_INTERVAL="$2"
            shift 2
            ;;
        --max-entries)
            MAX_ENTRIES="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

################################################################################
# File Lock Functions (prevent concurrent writes)
################################################################################

LOCK_FILE="${OUTPUT_FILE}.lock"
LOCK_TIMEOUT=10

acquire_lock() {
    local count=0
    while [ -f "$LOCK_FILE" ] && [ $count -lt $LOCK_TIMEOUT ]; do
        sleep 0.5
        count=$((count + 1))
    done
    
    if [ $count -eq $LOCK_TIMEOUT ]; then
        echo "Warning: Lock timeout, forcing lock acquisition"
        rm -f "$LOCK_FILE"
    fi
    
    echo $$ > "$LOCK_FILE"
}

release_lock() {
    rm -f "$LOCK_FILE"
}

################################################################################
# Core Monitoring Functions
################################################################################

get_cpu_info() {
    local cores=$(nproc)
    local model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs | jq -Rs '.')
    local load_avg=$(cat /proc/loadavg | jq -Rs '
        split(" ") | 
        {
            avg_1min: (.[0] | tonumber), 
            avg_5min: (.[1] | tonumber), 
            avg_15min: (.[2] | tonumber)
        }')
    
    local cpu_usage=$(grep 'cpu ' /proc/stat | awk '{
        usage=100-($5*100)/($2+$3+$4+$5+$6+$7+$8);
        printf "{\"usage_percent\": %.2f}", usage
    }')
    
    jq -n \
        --argjson cores "$cores" \
        --argjson model "$model" \
        --argjson load "$load_avg" \
        --argjson usage "$cpu_usage" \
        '{
            cores: $cores,
            model: $model,
            load: $load,
            current_usage: $usage
        }'
}

get_memory_info() {
    free -b | grep "^Mem:" | jq -Rs '
        split(" ") | 
        map(select(length > 0)) | 
        {
            total_bytes: (.[1] | tonumber), 
            used_bytes: (.[2] | tonumber), 
            free_bytes: (.[3] | tonumber), 
            available_bytes: (.[6] | tonumber),
            usage_percent: ((.[2] | tonumber) / (.[1] | tonumber) * 100)
        }'
}

get_disk_info() {
    df -B1 -l -t ext4 -t xfs -t btrfs -t ext3 2>/dev/null | tail -n +2 | jq -Rs '
        split("\n") | 
        map(select(length > 0) | split(" ") | map(select(length > 0))) | 
        map({
            filesystem: .[0], 
            size_bytes: (.[1] | tonumber), 
            used_bytes: (.[2] | tonumber), 
            available_bytes: (.[3] | tonumber), 
            use_percentage: (.[4] | rtrimstr("%") | tonumber), 
            mounted_on: .[5]
        })'
}

get_system_info() {
    local hostname=$(hostname)
    local kernel=$(uname -r)
    local uptime_seconds=$(cat /proc/uptime | cut -d' ' -f1 | cut -d'.' -f1)
    
    jq -n \
        --arg hostname "$hostname" \
        --arg kernel "$kernel" \
        --arg uptime_seconds "$uptime_seconds" \
        '{
            hostname: $hostname,
            kernel: $kernel,
            uptime_seconds: ($uptime_seconds | tonumber)
        }'
}

get_network_info() {
    if ip -j link show &>/dev/null; then
        ip -s -j link show 2>/dev/null | jq '[.[] | select(.ifname != "lo") | {
            interface: .ifname,
            state: .operstate,
            stats: {
                rx_bytes: .stats64.rx.bytes,
                tx_bytes: .stats64.tx.bytes
            }
        }]' 2>/dev/null || echo '[]'
    else
        echo '[]'
    fi
}

get_top_processes() {
    ps aux --sort=-%cpu 2>/dev/null | head -6 | awk 'NR>1 {
        cmd=$11; for(i=12;i<=NF;i++) cmd=cmd" "$i
        gsub(/"/, "\\\"", cmd)
        printf "{\"pid\":%s,\"cpu\":%.1f,\"mem\":%.1f,\"user\":\"%s\",\"command\":\"%s\"}\n",
        $2, $3, $4, $1, cmd
    }' | jq -s '.' 2>/dev/null || echo '[]'
}

################################################################################
# GitHub Context Functions
################################################################################

parse_repos_to_json() {
    local repos="$1"
    if [ -z "$repos" ]; then
        echo '[]'
        return
    fi
    
    echo "$repos" | jq -Rs '
        split(",") | 
        map(ltrimstr(" ") | rtrimstr(" ")) |
        map(select(length > 0)) |
        map({
            name: .,
            url: ("https://github.com/" + .)
        })'
}

################################################################################
# Data Collection Function
################################################################################

collect_entry() {
    # Use UTC timestamp in the specified format
    local timestamp=$(date -u '+%Y-%m-%d %H:%M:%S')
    local current_user=${USER_LOGIN:-$(whoami)}
    local repos_json=$(parse_repos_to_json "$GITHUB_REPOS")
    
    local entry='{}'
    
    # Add timestamp and GitHub context
    entry=$(echo "$entry" | jq \
        --arg ts "$timestamp" \
        --arg user "$current_user" \
        --argjson repos "$repos_json" \
        '{
            timestamp: $ts,
            github_context: {
                user: $user,
                repositories: $repos
            }
        } + .')
    
    # Add system info based on mode
    case "$MODE" in
        minimal)
            local cpu=$(get_cpu_info)
            local memory=$(get_memory_info)
            local disk=$(get_disk_info)
            
            entry=$(echo "$entry" | jq \
                --argjson cpu "$cpu" \
                --argjson memory "$memory" \
                --argjson disk "$disk" \
                '. + {
                    system: {
                        cpu: $cpu,
                        memory: $memory,
                        disk: $disk
                    }
                }')
            ;;
            
        extended)
            local cpu=$(get_cpu_info)
            local memory=$(get_memory_info)
            local disk=$(get_disk_info)
            local system=$(get_system_info)
            local network=$(get_network_info)
            local processes=$(get_top_processes)
            
            entry=$(echo "$entry" | jq \
                --argjson cpu "$cpu" \
                --argjson memory "$memory" \
                --argjson disk "$disk" \
                --argjson system "$system" \
                --argjson network "$network" \
                --argjson processes "$processes" \
                '. + {
                    system: {
                        info: $system,
                        cpu: $cpu,
                        memory: $memory,
                        disk: $disk,
                        network: $network,
                        top_processes: $processes
                    }
                }')
            ;;
            
        full)
            local cpu=$(get_cpu_info)
            local memory=$(get_memory_info)
            local disk=$(get_disk_info)
            local system=$(get_system_info)
            local network=$(get_network_info)
            local processes=$(get_top_processes)
            
            entry=$(echo "$entry" | jq \
                --argjson cpu "$cpu" \
                --argjson memory "$memory" \
                --argjson disk "$disk" \
                --argjson system "$system" \
                --argjson network "$network" \
                --argjson processes "$processes" \
                '. + {
                    system: {
                        info: $system,
                        cpu: $cpu,
                        memory: $memory,
                        disk: $disk,
                        network: $network,
                        top_processes: $processes
                    }
                }')
            ;;
    esac
    
    echo "$entry"
}

################################################################################
# Array Management Functions
################################################################################

initialize_file() {
    if [ ! -f "$OUTPUT_FILE" ]; then
        echo "[]" > "$OUTPUT_FILE"
        chmod 644 "$OUTPUT_FILE"
        echo "Initialized new monitoring file: $OUTPUT_FILE"
    else
        # Validate existing file is valid JSON array
        if ! jq -e '. | type == "array"' "$OUTPUT_FILE" > /dev/null 2>&1; then
            echo "Warning: Invalid JSON in $OUTPUT_FILE, creating backup and reinitializing"
            mv "$OUTPUT_FILE" "${OUTPUT_FILE}.backup.$(date +%s)"
            echo "[]" > "$OUTPUT_FILE"
        fi
    fi
}

append_entry() {
    local new_entry="$1"
    
    acquire_lock
    
    # Read existing array, append new entry, trim if needed
    local temp_file="${OUTPUT_FILE}.tmp"
    
    jq --argjson entry "$new_entry" --argjson max "$MAX_ENTRIES" '
        . + [$entry] | 
        if length > $max then .[-$max:] else . end
    ' "$OUTPUT_FILE" > "$temp_file"
    
    # Atomically replace the file
    mv "$temp_file" "$OUTPUT_FILE"
    
    release_lock
    
    # Get current array size for logging
    local array_size=$(jq 'length' "$OUTPUT_FILE")
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Entry added. Total entries: $array_size"
}

################################################################################
# Statistics Function
################################################################################

print_stats() {
    if [ -f "$OUTPUT_FILE" ]; then
        local stats=$(jq -r '
            if length > 0 then
                {
                    total_entries: length,
                    first_timestamp: first.timestamp,
                    last_timestamp: last.timestamp,
                    avg_cpu: ([.[].system.cpu.current_usage.usage_percent] | add / length),
                    avg_memory: ([.[].system.memory.usage_percent] | add / length)
                } |
                "Statistics:\n" +
                "  Total entries: \(.total_entries)\n" +
                "  First entry: \(.first_timestamp)\n" +
                "  Last entry: \(.last_timestamp)\n" +
                "  Average CPU: \(.avg_cpu | tostring[0:5])%\n" +
                "  Average Memory: \(.avg_memory | tostring[0:5])%"
            else
                "No data collected yet"
            end
        ' "$OUTPUT_FILE" 2>/dev/null || echo "Unable to calculate statistics")
        
        echo "$stats"
    fi
}

################################################################################
# Main Monitoring Loop
################################################################################

main() {
    echo "═══════════════════════════════════════════════════════════"
    echo "System Monitor with GitHub Context - JSON Array Mode"
    echo "═══════════════════════════════════════════════════════════"
    echo "Output file: $OUTPUT_FILE"
    echo "Mode: $MODE"
    echo "User: ${USER_LOGIN:-$(whoami)}"
    [ -n "$GITHUB_REPOS" ] && echo "Monitoring repos: $GITHUB_REPOS"
    echo "Update interval: ${UPDATE_INTERVAL} minute(s)"
    echo "Max entries: $MAX_ENTRIES"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    # Initialize or validate file
    initialize_file
    
    # Print initial stats if file has data
    print_stats
    echo ""
    
    echo "Starting continuous monitoring..."
    echo "Press Ctrl+C to stop"
    echo ""
    
    # Main monitoring loop
    while true; do
        echo -n "[$(date '+%Y-%m-%d %H:%M:%S')] Collecting data... "
        
        # Collect and append entry
        entry=$(collect_entry)
        append_entry "$entry"
        
        # Show brief status
        if [ "$MODE" = "minimal" ]; then
            cpu_usage=$(echo "$entry" | jq -r '.system.cpu.current_usage.usage_percent')
            mem_usage=$(echo "$entry" | jq -r '.system.memory.usage_percent')
            printf "CPU: %.1f%%, Memory: %.1f%%\n" "$cpu_usage" "$mem_usage"
        fi
        
        # Wait for next interval
        echo "Next collection in ${UPDATE_INTERVAL} minute(s)..."
        sleep $((UPDATE_INTERVAL * 60))
    done
}

# Cleanup function
cleanup() {
    echo ""
    echo "Monitoring stopped."
    print_stats
    release_lock
    exit 0
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM

# Run main function
main