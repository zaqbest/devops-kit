#!/usr/bin/env bash
# Logging utilities — source this file, do not execute directly.

LOG_LEVEL="${LOG_LEVEL:-INFO}"
LOG_FILE="${LOG_FILE:-/var/log/devops-kit.log}"

# Color constants (disabled when no TTY or NO_COLOR is set)
_log_colors_enabled() { [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; }

_C_RESET='\033[0m'
_C_RED='\033[0;31m'
_C_YELLOW='\033[0;33m'
_C_GREEN='\033[0;32m'
_C_CYAN='\033[0;36m'
_C_MAGENTA='\033[0;35m'
_C_BOLD='\033[1m'

_log_write() {
    local level="$1" color="$2" msg="$3"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local line="[$timestamp] [$level] $msg"

    # Write to log file (no color)
    if [ -n "$LOG_FILE" ]; then
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
        printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
    fi

    # Write to terminal (with color)
    if _log_colors_enabled; then
        printf "${color}[${level}]${_C_RESET} %s\n" "$msg"
    else
        printf '[%s] %s\n' "$level" "$msg"
    fi
}

log_info()  { _log_write "INFO " "$_C_GREEN"   "$*"; }
log_warn()  { _log_write "WARN " "$_C_YELLOW"  "$*" >&2; }
log_error() { _log_write "ERROR" "$_C_RED"     "$*" >&2; }
log_dry()   { _log_write "DRY  " "$_C_MAGENTA" "$*"; }

log_step() {
    local step="$1" total="$2"; shift 2
    local msg="$*"
    if _log_colors_enabled; then
        printf "${_C_CYAN}${_C_BOLD}[%s/%s]${_C_RESET} %s\n" "$step" "$total" "$msg"
    else
        printf '[%s/%s] %s\n' "$step" "$total" "$msg"
    fi
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] [STEP %s/%s] %s\n' "$timestamp" "$step" "$total" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

die() {
    local msg="$1" code="${2:-1}"
    log_error "$msg"
    exit "$code"
}

banner() {
    local title="$1"
    local len=${#title}
    local line
    line=$(printf '%*s' $(( len + 4 )) '' | tr ' ' '=')
    if _log_colors_enabled; then
        printf "${_C_BOLD}%s\n  %s  \n%s${_C_RESET}\n" "$line" "$title" "$line"
    else
        printf '%s\n  %s  \n%s\n' "$line" "$title" "$line"
    fi
}

# ERR trap — call via: trap 'error_handler $LINENO $?' ERR
error_handler() {
    local lineno="$1" status="$2"
    log_error "Script failed at line $lineno with exit status $status"
    local i=0
    while caller $i &>/dev/null; do
        local frame
        frame=$(caller $i)
        log_error "  Call stack [$i]: $frame"
        (( i++ )) || true
    done
}
