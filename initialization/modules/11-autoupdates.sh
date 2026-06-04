#!/usr/bin/env bash
# Module 11: Configure automatic security updates
PHASE_KEY="AUTO_UPDATES_CONFIGURED"

main() {
    if [ "${AUTO_UPDATES_ENABLED:-1}" = "0" ]; then
        log_info "Auto-updates disabled by configuration, skipping."
        return 0
    fi

    [ "${AUTO_UPDATES_CONFIGURED:-0}" = "1" ] && { log_info "Auto-updates already configured, skipping."; return 0; }

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dry "Would configure automatic security updates"
        return 0
    fi

    case "$OS_FAMILY" in
        debian)
            pkg_install_if_missing unattended-upgrades apt-listchanges

            cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

            cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

            service_enable_start unattended-upgrades
            ;;

        rhel)
            if [ "${OS_VERSION_MAJOR:-8}" -ge 8 ]; then
                pkg_install_if_missing dnf-automatic
                sed -i 's/^apply_updates = .*/apply_updates = yes/' \
                    /etc/dnf/automatic.conf 2>/dev/null || true
                systemctl enable --now dnf-automatic.timer
            else
                # CentOS 7 / RHEL 7
                pkg_install_if_missing yum-cron
                sed -i 's/^apply_updates = .*/apply_updates = yes/' \
                    /etc/yum/yum-cron.conf 2>/dev/null || true
                service_enable_start yum-cron
            fi
            ;;

        alpine)
            # Add daily upgrade cron job
            mkdir -p /etc/periodic/daily
            cat > /etc/periodic/daily/apk-upgrade <<'EOF'
#!/bin/sh
apk update -q && apk upgrade -q --available
EOF
            chmod +x /etc/periodic/daily/apk-upgrade
            ;;
    esac

    log_info "Automatic security updates configured."
}
