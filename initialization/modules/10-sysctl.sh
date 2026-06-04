#!/usr/bin/env bash
# Module 10: Kernel parameter tuning via sysctl
PHASE_KEY="SYSCTL_TUNED"

main() {
    if [ "${SYSCTL_TUNING_ENABLED:-1}" = "0" ]; then
        log_info "sysctl tuning disabled, skipping."
        return 0
    fi

    [ "${SYSCTL_TUNED:-0}" = "1" ] && { log_info "sysctl already tuned, skipping."; return 0; }

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dry "Would write /etc/sysctl.d/99-devops-kit.conf and apply settings"
        return 0
    fi

    log_info "Applying kernel tuning parameters..."

    mkdir -p /etc/sysctl.d

    cat > /etc/sysctl.d/99-devops-kit.conf <<'EOF'
# Network performance
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

# Security hardening
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2

# Swap tuning
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF

    sysctl --system
    log_info "Kernel tuning applied."
}
