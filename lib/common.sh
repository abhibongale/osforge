#!/bin/bash
# Common utilities for OSForge

# Colors for output
COLOR_RESET='\033[0m'
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_CYAN='\033[0;36m'

# Default settings
DEFAULT_BASE_IMAGE="quay.io/osforge/base:latest"
DEFAULT_RUNTIME="podman"
DEFAULT_MEMORY="8G"
DEFAULT_CPUS="4"
DEFAULT_TIMEOUT="3600"

# Initialize OSForge
init_osforge() {
    # Create user directory if it doesn't exist
    mkdir -p "$OSFORGE_USER_DIR"/{logs,cache/{images,pip},volumes}

    # Load user config if exists
    if [[ -f "$OSFORGE_USER_DIR/config.yaml" ]]; then
        # TODO: Parse YAML config
        : # placeholder
    fi

    # Set defaults
    RUNTIME="${RUNTIME:-$DEFAULT_RUNTIME}"
    BASE_IMAGE="${BASE_IMAGE:-$DEFAULT_BASE_IMAGE}"
    MEMORY="${MEMORY:-$DEFAULT_MEMORY}"
    CPUS="${CPUS:-$DEFAULT_CPUS}"
    TIMEOUT="${TIMEOUT:-$DEFAULT_TIMEOUT}"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
check_prereqs() {
    local errors=0

    # Check container runtime
    if ! command_exists "$RUNTIME"; then
        log_error "Container runtime '$RUNTIME' not found"
        log_error "Install with: sudo dnf install podman"
        ((errors++))
    fi

    # Check KVM access
    if [[ ! -r /dev/kvm ]]; then
        log_warn "Cannot read /dev/kvm"
        log_warn "Add yourself to kvm group: sudo usermod -a -G kvm \$USER"
        ((errors++))
    fi

    # Check resources
    local available_mem
    available_mem=$(awk '/MemAvailable/ {print int($2/1024/1024)}' /proc/meminfo)
    if [[ $available_mem -lt 8 ]]; then
        log_warn "Low memory: ${available_mem}GB available (8GB+ recommended)"
    fi

    return $errors
}

# Get timestamp for log directories
get_timestamp() {
    date +%Y-%m-%d-%H%M%S
}

# Find latest log directory
get_latest_log_dir() {
    local latest
    latest=$(find "$OSFORGE_USER_DIR/logs" -maxdepth 1 -type d -name "20*" 2>/dev/null | sort -r | head -1)
    if [[ -n "$latest" ]]; then
        echo "$latest"
    else
        echo ""
    fi
}

# Create log directory for run
create_log_dir() {
    local timestamp
    timestamp=$(get_timestamp)
    local log_dir="$OSFORGE_USER_DIR/logs/$timestamp"

    mkdir -p "$log_dir"

    # Update latest symlink
    rm -f "$OSFORGE_USER_DIR/logs/latest"
    ln -sf "$log_dir" "$OSFORGE_USER_DIR/logs/latest"

    echo "$log_dir"
}

# Parse simple YAML (very basic, just for job configs)
yaml_get() {
    local file="$1"
    local key="$2"

    if [[ ! -f "$file" ]]; then
        return 1
    fi

    # Handle nested keys (e.g., "test.regex" -> section: test, key: regex)
    if [[ "$key" == *.* ]]; then
        local section="${key%%.*}"
        local subkey="${key#*.}"

        # Extract the section and find the subkey within it
        awk -v section="$section" -v subkey="$subkey" '
            /^[a-z]/ { in_section=0 }
            $0 ~ "^" section ":" { in_section=1; next }
            in_section && $1 ~ "^" subkey ":" {
                sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "")
                gsub(/"/, "")
                gsub(/'\''/, "")
                print
                exit
            }
        ' "$file"
    else
        # Simple top-level key
        grep "^${key}:" "$file" | sed "s/^${key}:[[:space:]]*//" | tr -d '"' | tr -d "'"
    fi
}

# Resolve path (handle ~)
resolve_path() {
    local path="$1"

    # Expand ~
    path="${path/#\~/$HOME}"

    # Make absolute
    if [[ ! "$path" = /* ]]; then
        path="$(pwd)/$path"
    fi

    echo "$path"
}

# Check if directory is a git repo with specific project
is_ironic_repo() {
    local dir="$1"

    if [[ ! -d "$dir/.git" ]]; then
        return 1
    fi

    if [[ -f "$dir/setup.py" ]] && grep -q "name.*ironic" "$dir/setup.py" 2>/dev/null; then
        return 0
    fi

    return 1
}

# Get container name for job
get_container_name() {
    local job_name="$1"
    echo "osforge-${job_name}-$(date +%s)"
}

# Save run metadata
save_run_metadata() {
    local log_dir="$1"
    local job_name="$2"
    local ironic_repo="$3"

    cat > "$log_dir/metadata.txt" << EOF
Job: $job_name
Timestamp: $(date)
Ironic Repo: ${ironic_repo:-N/A}
Base Image: $BASE_IMAGE
Runtime: $RUNTIME
EOF
}
