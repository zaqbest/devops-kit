#!/usr/bin/env bash
# Module 05: Create non-root sudo admin user
PHASE_KEY="ADMIN_USER_CREATED"

main() {
    local user="${ADMIN_USER:-devops}"

    if id "$user" &>/dev/null; then
        log_info "User '$user' already exists."
    else
        log_info "Creating admin user: $user"
        case "$OS_FAMILY" in
            debian)
                useradd -m -s /bin/bash -G sudo "$user"
                ;;
            rhel)
                useradd -m -s /bin/bash -G wheel "$user"
                ;;
            alpine)
                pkg_install_if_missing sudo
                adduser -D -s /bin/bash "$user"
                addgroup "$user" wheel
                ;;
        esac
    fi

    # Ensure sudo group is configured
    case "$OS_FAMILY" in
        rhel|alpine)
            if ! grep -qE '^%wheel\s+ALL=\(ALL\)' /etc/sudoers; then
                echo '%wheel ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
            fi
            ;;
        debian)
            if ! grep -qE '^%sudo\s+ALL=\(ALL\)' /etc/sudoers; then
                echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
            fi
            ;;
    esac

    # SSH key setup
    local user_home
    user_home=$(getent passwd "$user" | cut -d: -f6)
    local ssh_dir="$user_home/.ssh"

    if [ -n "${ADMIN_SSH_KEY:-}" ]; then
        mkdir -p "$ssh_dir"
        chmod 700 "$ssh_dir"
        if ! grep -qF "$ADMIN_SSH_KEY" "$ssh_dir/authorized_keys" 2>/dev/null; then
            echo "$ADMIN_SSH_KEY" >> "$ssh_dir/authorized_keys"
            log_info "SSH public key added for $user"
        fi
        chmod 600 "$ssh_dir/authorized_keys"
        chown -R "$user:$user" "$ssh_dir"
    else
        log_warn "No ADMIN_SSH_KEY set. Set a password for '$user'."
        if [ "${INTERACTIVE:-1}" = "1" ]; then
            passwd "$user"
        fi
        # Cannot disable password auth without a key
        SSH_DISABLE_PASSWORD_AUTH=0
    fi

    log_warn "IMPORTANT: Test sudo access as '$user' before closing the root session!"
    log_info "Admin user '$user' configured."
}
