#!/usr/bin/env bash
# Module 07: SSH hardening
PHASE_KEY="SSH_HARDENED"

_sshd_config_set() {
    local key="$1" value="$2" file="${3:-/etc/ssh/sshd_config}"
    if grep -qE "^#?${key}\s" "$file"; then
        sed -i -E "s|^#?${key}\s.*|${key} ${value}|" "$file"
    else
        echo "$key $value" >> "$file"
    fi
}

main() {
    [ "${SSH_HARDENED:-0}" = "1" ] && { log_info "SSH already hardened, skipping."; return 0; }

    local ssh_port="${SSH_PORT:-22}"
    local disable_root="${SSH_DISABLE_ROOT:-1}"
    local disable_pw="${SSH_DISABLE_PASSWORD_AUTH:-1}"

    log_info "Hardening SSH (port: $ssh_port)..."

    # Use drop-in config directory if supported
    local dropin_dir="/etc/ssh/sshd_config.d"
    local use_dropin=0

    if [ -d "$dropin_dir" ] && grep -q "Include $dropin_dir" /etc/ssh/sshd_config 2>/dev/null; then
        use_dropin=1
    fi

    if [ "$use_dropin" = "1" ] && [ "${DRY_RUN:-0}" != "1" ]; then
        log_info "Writing SSH hardening drop-in: $dropin_dir/99-devops-kit.conf"
        cp "${DEVOPS_KIT_ROOT}/initialization/config/sshd_hardening.conf" \
           "$dropin_dir/99-devops-kit.conf"

        # Port and auth settings go in drop-in too
        {
            echo "Port $ssh_port"
            [ "$disable_root" = "1" ] && echo "PermitRootLogin no"
            [ "$disable_pw"   = "1" ] && echo "PasswordAuthentication no"
        } >> "$dropin_dir/99-devops-kit.conf"
    else
        # Direct edit for older systems
        backup_file /etc/ssh/sshd_config

        if [ "${DRY_RUN:-0}" = "1" ]; then
            log_dry "Would edit /etc/ssh/sshd_config: Port=$ssh_port PermitRootLogin=no PasswordAuthentication=$( [ "$disable_pw" = "1" ] && echo no || echo yes)"
        else
            _sshd_config_set Port              "$ssh_port"
            _sshd_config_set PubkeyAuthentication yes
            _sshd_config_set AuthorizedKeysFile   ".ssh/authorized_keys"
            _sshd_config_set X11Forwarding         no
            _sshd_config_set MaxAuthTries          3
            _sshd_config_set LoginGraceTime        30
            _sshd_config_set ClientAliveInterval   300
            _sshd_config_set ClientAliveCountMax   2
            _sshd_config_set AllowAgentForwarding  no
            _sshd_config_set TCPKeepAlive          no
            [ "$disable_root" = "1" ] && _sshd_config_set PermitRootLogin no
            [ "$disable_pw"   = "1" ] && _sshd_config_set PasswordAuthentication no
        fi
    fi

    if [ "${DRY_RUN:-0}" != "1" ]; then
        # Validate config before reloading
        if ! sshd -t; then
            log_error "sshd_config validation failed! Restoring backup..."
            [ -f /etc/ssh/sshd_config.bak.* ] && \
                cp "$(ls -t /etc/ssh/sshd_config.bak.* | head -1)" /etc/ssh/sshd_config
            die "SSH hardening aborted due to config error."
        fi

        # Reload (not restart — preserve existing sessions)
        service_reload sshd 2>/dev/null || service_reload ssh 2>/dev/null || true
    fi

    if [ "$ssh_port" != "22" ]; then
        log_warn "========================================================"
        log_warn "  SSH is now on port $ssh_port"
        log_warn "  Update your firewall rules BEFORE disconnecting!"
        log_warn "========================================================"
    fi

    log_info "SSH hardening complete."
}
