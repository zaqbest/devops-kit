#!/usr/bin/env bash
# Module 02: Set system hostname
PHASE_KEY="HOSTNAME_SET"

main() {
    if [ -z "${HOSTNAME_DESIRED:-}" ]; then
        log_info "HOSTNAME_DESIRED not set, skipping hostname configuration."
        return 0
    fi

    local current_hostname
    current_hostname=$(hostname -s 2>/dev/null || hostname)

    if [ "$current_hostname" = "$HOSTNAME_DESIRED" ]; then
        [ "${HOSTNAME_SET:-0}" = "1" ] && { log_info "Hostname already set to $HOSTNAME_DESIRED, skipping."; return 0; }
    fi

    log_info "Setting hostname: $HOSTNAME_DESIRED"

    if has_systemd; then
        hostnamectl set-hostname "$HOSTNAME_DESIRED"
    else
        echo "$HOSTNAME_DESIRED" > /etc/hostname
        hostname -F /etc/hostname
    fi

    # Update /etc/hosts — replace or add 127.0.1.1 line
    backup_file /etc/hosts
    if grep -q '127\.0\.1\.1' /etc/hosts; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$HOSTNAME_DESIRED/" /etc/hosts
    else
        echo -e "127.0.1.1\t$HOSTNAME_DESIRED" >> /etc/hosts
    fi

    log_info "Hostname set to: $HOSTNAME_DESIRED"
}
