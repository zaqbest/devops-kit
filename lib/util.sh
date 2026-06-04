#!/usr/bin/env bash
# General utilities — source this file, do not execute directly.

TEMP_DIRS=()

# Interactive confirmation prompt; auto-answers with DEFAULT when INTERACTIVE=0
confirm() {
    local prompt="$1" default="${2:-y}"
    if [ "${INTERACTIVE:-1}" = "0" ]; then
        log_info "Auto-confirming: $prompt [default: $default]"
        [[ "$default" =~ ^[Yy] ]] && return 0 || return 1
    fi
    local reply
    read -rp "$prompt [y/N] " reply
    [[ "${reply:-$default}" =~ ^[Yy] ]]
}

# Retry a command N times with DELAY seconds between attempts
retry() {
    local n="$1" delay="$2"; shift 2
    local attempt=1
    until "$@"; do
        if [ "$attempt" -ge "$n" ]; then
            log_error "Command failed after $n attempts: $*"
            return 1
        fi
        log_warn "Attempt $attempt failed, retrying in ${delay}s..."
        sleep "$delay"
        (( attempt++ )) || true
    done
}

trim() { local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; echo "$s"; }

to_mb() { echo $(( ${1} / 1024 / 1024 )); }
to_gb() { echo $(( ${1} / 1024 / 1024 / 1024 )); }

number_clamp() {
    local val="$1" min="$2" max="$3"
    if [ "$val" -lt "$min" ]; then echo "$min"
    elif [ "$val" -gt "$max" ]; then echo "$max"
    else echo "$val"
    fi
}

file_contains_line() {
    local file="$1" pattern="$2"
    grep -qF "$pattern" "$file" 2>/dev/null
}

file_add_line_if_missing() {
    local file="$1" line="$2"
    if ! file_contains_line "$file" "$line"; then
        echo "$line" >> "$file"
        log_info "Added to $file: $line"
    fi
}

backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        local backup="${file}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$file" "$backup"
        log_info "Backed up: $file → $backup"
    fi
}

require_cmd() {
    local cmd="$1" hint="${2:-install $1}"
    if ! command -v "$cmd" &>/dev/null; then
        die "Required command not found: $cmd. $hint"
    fi
}

mktemp_dir() {
    local prefix="${1:-devops-kit}"
    local dir
    dir=$(mktemp -d "/tmp/${prefix}.XXXXXX")
    TEMP_DIRS+=("$dir")
    echo "$dir"
}

cleanup_temp_dirs() {
    local dir
    for dir in "${TEMP_DIRS[@]+"${TEMP_DIRS[@]}"}"; do
        rm -rf "$dir"
    done
}
