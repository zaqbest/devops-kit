#!/usr/bin/env bash
# Privilege helpers — source this file, do not execute directly.

is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }

require_root() {
    if is_root; then return 0; fi

    if command -v sudo &>/dev/null; then
        log_info "Re-launching as root via sudo..."
        exec sudo bash "$0" "$@"
    else
        die "This script must be run as root. Install sudo or run as root directly."
    fi
}

# Run a command as a specific user
run_as() {
    local user="$1"; shift
    su -s /bin/bash -c "$*" "$user"
}

# Drop privileges to a named user for subsequent interactive work
drop_privileges_to() {
    local user="$1"
    if is_root && id "$user" &>/dev/null; then
        log_info "Dropping privileges to user: $user"
        exec su -l "$user"
    fi
}
