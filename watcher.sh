#!/usr/bin/env bash
set -euo pipefail

########################################
#           CONFIGURATION              #
########################################
# Multi-path configuration (new approach)
# Space-separated list of host paths to monitor for file changes
MONITOR_PATHS="${MONITOR_PATHS:-${WATCH_DIR:-}}"
# Space-separated list of matching Nextcloud data paths for scanning
NC_SCAN_PATHS="${NC_SCAN_PATHS:-${SCAN_PATHS:-}}"

# Legacy single-path support for backward compatibility
# If old variables are set but new ones aren't, use legacy mode
if [[ -z "$MONITOR_PATHS" && -n "${WATCH_DIR:-}" ]]; then
    MONITOR_PATHS="$WATCH_DIR"
fi

# Container and execution configuration
NEXTCLOUD_CONTAINER="${NEXTCLOUD_CONTAINER:-nextcloud}"
SCAN_USER="${SCAN_USER:-www-data}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# Convert LOG_LEVEL to uppercase for case-insensitive comparison
LOG_LEVEL="${LOG_LEVEL^^}"

# inotify events to monitor (customizable for advanced users)
INOTIFY_EVENTS="${INOTIFY_EVENTS:-create,delete,modify,move}"

########################################
#             FUNCTIONS                #
########################################

# Logging function with level filtering
log() {
    # Usage: log LEVEL message...
    local level="$1"; shift
    # Only log if: exact match, DEBUG mode (shows all), or ERROR (always shown)
    if [[ "$level" == "$LOG_LEVEL" || "$LOG_LEVEL" == "DEBUG" || "$level" == "ERROR" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    fi
}

# Fatal error function - logs error and exits
fatal() { 
    log ERROR "$*"
    exit 1
}

# Build the occ files:scan command for a specific Nextcloud path
build_scan_cmd() {
    # $1 = Nextcloud path (e.g., "/user1/files/Photos/2024")
    # Returns properly quoted occ command
    printf 'php occ files:scan --path="%s"' "$1"
}

# Normalize path by removing trailing slashes and empty components
normalize_path() {
    local path="$1"
    # Remove trailing slashes except for root
    path="${path%/}"
    [[ -z "$path" ]] && path="/"
    echo "$path"
}

# Find which monitor index a changed file belongs to
find_monitor_index() {
    local changed_file="$1"
    local i
    
    for i in "${!MONITOR[@]}"; do
        local root
        root=$(normalize_path "${MONITOR[$i]}")
        case "$changed_file" in
            "$root"/*)
                echo "$i"
                return 0
                ;;
        esac
    done
    
    # File doesn't match any monitored path (shouldn't happen with inotifywait)
    log DEBUG "File '$changed_file' doesn't match any monitored paths"
    return 1
}

# Convert container file path to Nextcloud scan path
container_to_nextcloud_path() {
    local changed_file="$1"
    local monitor_idx="$2"
    
    local monitor_root
    local nc_base
    local relative_path
    local nc_full_path
    
    monitor_root=$(normalize_path "${MONITOR[$monitor_idx]}")
    nc_base=$(normalize_path "${NC_SCAN[$monitor_idx]}")
    
    # Strip the monitor root from the changed file path to get relative path
    relative_path="${changed_file#$monitor_root/}"
    
    # For file changes, we want to scan the containing directory
    # because occ files:scan works on directories, not individual files
    relative_dir=$(dirname "$relative_path")
    
    # Handle root directory case
    if [[ "$relative_dir" == "." ]]; then
        nc_full_path="$nc_base"
    else
        nc_full_path="$nc_base/$relative_dir"
    fi
    
    echo "$nc_full_path"
}

########################################
#          VALIDATION STAGE            #
########################################

log INFO "Starting Nextcloud watcher validation..."

# 1. Check Docker socket availability
if [[ ! -e /var/run/docker.sock ]]; then
    fatal "Docker socket not mounted at /var/run/docker.sock - this is required!"
fi

# 2. Test Docker CLI connectivity
if ! docker ps >/dev/null 2>&1; then
    fatal "Cannot communicate with Docker daemon - check socket permissions"
fi

# 3. Verify Nextcloud container is running
if ! docker ps --format '{{.Names}}' | grep -qx "${NEXTCLOUD_CONTAINER}"; then
    fatal "Nextcloud container '${NEXTCLOUD_CONTAINER}' is not running"
fi

# 4. Parse and validate path configuration
if [[ -z "$MONITOR_PATHS" ]]; then
    fatal "No MONITOR_PATHS defined - at least one path must be specified"
fi

# Convert space-separated strings to arrays
IFS=' ' read -r -a MONITOR <<<"$MONITOR_PATHS"
IFS=' ' read -r -a NC_SCAN <<<"$NC_SCAN_PATHS"

# Auto-fallback: if NC_SCAN_PATHS is empty but exactly one monitor path,
# default to scanning from Nextcloud root (/) - useful for quick testing
if [[ -z "$NC_SCAN_PATHS" && ${#MONITOR[@]} -eq 1 ]]; then
    log INFO "NC_SCAN_PATHS not set with single monitor path, defaulting to root scan '/'"
    NC_SCAN_PATHS="/"
    IFS=' ' read -r -a NC_SCAN <<<"$NC_SCAN_PATHS"
fi

# 5. Validate path array lengths match
if [[ ${#MONITOR[@]} -ne ${#NC_SCAN[@]} ]]; then
    fatal "MONITOR_PATHS and NC_SCAN_PATHS must have the same number of items"
    log ERROR "  MONITOR_PATHS has ${#MONITOR[@]} items: ${MONITOR[*]}"
    log ERROR "  NC_SCAN_PATHS has ${#NC_SCAN[@]} items: ${NC_SCAN[*]}"
fi

# 6. Check that all monitor paths exist and are directories
for i in "${!MONITOR[@]}"; do
    local path="${MONITOR[$i]}"
    if [[ ! -d "$path" ]]; then
        fatal "Monitor path '$path' does not exist or is not a directory"
    fi
done

# 7. Test that we can execute commands in the Nextcloud container
log DEBUG "Testing occ command availability in Nextcloud container..."
if ! docker exec -u "$SCAN_USER" "$NEXTCLOUD_CONTAINER" php occ --version >/dev/null 2>&1; then
    log ERROR "Cannot execute 'php occ' in Nextcloud container - check user permissions"
    log ERROR "Container: $NEXTCLOUD_CONTAINER, User: $SCAN_USER"
    exit 1
fi

########################################
#          STARTUP LOGGING             #
########################################

log INFO "✓ Validation complete - starting file monitoring"
log INFO "Configuration:"
log INFO "  Nextcloud container: $NEXTCLOUD_CONTAINER"
log INFO "  Scan user: $SCAN_USER"
log INFO "  Log level: $LOG_LEVEL"
log INFO "Path mappings:"

for i in "${!MONITOR[@]}"; do
    log INFO "  [${i}] Monitor: '${MONITOR[$i]}' → Scan: '${NC_SCAN[$i]}'"
done

########################################
#           MAIN EVENT LOOP            #
########################################

log INFO "Starting inotifywait on ${#MONITOR[@]} path(s)..."

# Launch inotifywait with all monitor paths
# Events: configurable via INOTIFY_EVENTS (default: create,delete,modify,move)
# Format: full path of changed file
inotifywait -m -r -e "$INOTIFY_EVENTS" --format '%w%f' "${MONITOR[@]}" | \
while read -r changed_file; do
    log DEBUG "Raw inotify event: '$changed_file'"
    
    # Find which monitor path this file belongs to
    if monitor_idx=$(find_monitor_index "$changed_file"); then
        # Convert container path to Nextcloud path
        nc_path=$(container_to_nextcloud_path "$changed_file" "$monitor_idx")
        
        log INFO "File change detected: $(basename "$changed_file")"
        log DEBUG "  Container path: $changed_file"
        log DEBUG "  Monitor index: $monitor_idx (${MONITOR[$monitor_idx]})"
        log DEBUG "  Nextcloud path: $nc_path"
        
        # Build and execute the scan command
        scan_cmd=$(build_scan_cmd "$nc_path")
        
        if [[ "$LOG_LEVEL" == "DEBUG" ]]; then
            log DEBUG "Executing: docker exec -u $SCAN_USER $NEXTCLOUD_CONTAINER $scan_cmd"
        fi
        
        # Execute the scan in the Nextcloud container
        if docker exec -u "$SCAN_USER" "$NEXTCLOUD_CONTAINER" sh -c "$scan_cmd" >/dev/null 2>&1; then
            log INFO "✓ Scan completed successfully for: $nc_path"
        else
            log ERROR "✗ Scan failed for: $nc_path"
            log ERROR "  Check Nextcloud container logs: docker logs $NEXTCLOUD_CONTAINER"
        fi
    else
        log DEBUG "Ignoring file outside monitored paths: $changed_file"
    fi
done

# This line should never be reached unless inotifywait exits
log ERROR "inotifywait process terminated unexpectedly"
# Exit with non-zero status so health checks can detect failure
exit 2
