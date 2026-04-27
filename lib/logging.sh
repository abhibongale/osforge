#!/bin/bash
# Logging utilities for OSForge

# Log levels
LOG_LEVEL_DEBUG=0
LOG_LEVEL_INFO=1
LOG_LEVEL_WARN=2
LOG_LEVEL_ERROR=3

# Current log level (default: INFO)
CURRENT_LOG_LEVEL=${CURRENT_LOG_LEVEL:-$LOG_LEVEL_INFO}

# Log functions
log_debug() {
    if [[ $CURRENT_LOG_LEVEL -le $LOG_LEVEL_DEBUG ]]; then
        echo -e "${COLOR_CYAN}[DEBUG]${COLOR_RESET} $*" >&2
    fi
}

log_info() {
    if [[ $CURRENT_LOG_LEVEL -le $LOG_LEVEL_INFO ]]; then
        echo -e "${COLOR_BLUE}[osforge]${COLOR_RESET} $*"
    fi
}

log_success() {
    echo -e "${COLOR_GREEN}✓${COLOR_RESET} $*"
}

log_warn() {
    if [[ $CURRENT_LOG_LEVEL -le $LOG_LEVEL_WARN ]]; then
        echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $*" >&2
    fi
}

log_error() {
    if [[ $CURRENT_LOG_LEVEL -le $LOG_LEVEL_ERROR ]]; then
        echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
    fi
}

log_step() {
    echo -e "${COLOR_CYAN}==>${COLOR_RESET} $*"
}

# Show a spinner for long-running operations
show_spinner() {
    local pid=$1
    local message="$2"
    local delay=0.1
    local spinstr='|/-\'

    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c] %s\r" "$spinstr" "$message"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
    done

    printf "    \r"
}

# Progress indicator
show_progress() {
    local current=$1
    local total=$2
    local message="$3"

    local percent=$((current * 100 / total))
    local filled=$((percent / 2))
    local empty=$((50 - filled))

    printf "\r[${COLOR_GREEN}"
    printf "%${filled}s" | tr ' ' '='
    printf "${COLOR_RESET}"
    printf "%${empty}s" | tr ' ' '-'
    printf "] %3d%% %s" "$percent" "$message"
}
