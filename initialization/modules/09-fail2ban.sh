#!/usr/bin/env bash
# Module 09: Install and configure fail2ban
PHASE_KEY="FAIL2BAN_CONFIGURED"

main() {
    if [ "${FAIL2BAN_ENABLED:-1}" = "0" ]; then
        log_info "fail2ban disabled by configuration, skipping."
        return 0
    fi

    [ "${FAIL2BAN_CONFIGURED:-0}" = "1" ] && { log_info "fail2ban already configured, skipping."; return 0; }

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dry "Would install and configure fail2ban"
        return 0
    fi

    pkg_install_if_missing fail2ban

    local bantime="${FAIL2BAN_BANTIME:-3600}"
    local maxretry="${FAIL2BAN_MAXRETRY:-5}"
    local ssh_port="${SSH_PORT:-22}"

    # Write jail.local (survives package upgrades, unlike jail.conf)
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime   = $bantime
maxretry  = $maxretry
findtime  = 600
ignoreip  = 127.0.0.1/8 ::1

[sshd]
enabled = true
port    = $ssh_port
EOF

    # RHEL/systemd: use systemd backend
    if has_systemd && [ "$OS_FAMILY" = "rhel" ]; then
        sed -i '/\[DEFAULT\]/a backend = systemd' /etc/fail2ban/jail.local
    fi

    service_enable_start fail2ban

    # Verify
    if fail2ban-client status sshd &>/dev/null; then
        log_info "fail2ban active — sshd jail running."
    else
        log_warn "fail2ban installed but sshd jail status check failed."
    fi
}
