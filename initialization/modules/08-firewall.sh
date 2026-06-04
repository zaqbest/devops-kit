#!/usr/bin/env bash
# Module 08: Firewall configuration (ufw / firewalld / iptables)
PHASE_KEY="FIREWALL_CONFIGURED"

_open_ufw() {
    local port="$1" proto="$2"
    ufw allow "${port}/${proto}" comment 'devops-kit' 2>/dev/null || true
}

_open_firewalld() {
    local port="$1" proto="$2"
    firewall-cmd --permanent --add-port="${port}/${proto}" 2>/dev/null || true
}

_open_iptables() {
    local port="$1" proto="$2"
    iptables -A INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
}

main() {
    [ "${FIREWALL_CONFIGURED:-0}" = "1" ] && { log_info "Firewall already configured, skipping."; return 0; }

    local tcp_ports="${UFW_ALLOWED_TCP_PORTS:-22 80 443}"
    local udp_ports="${UFW_ALLOWED_UDP_PORTS:-}"

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log_dry "Would configure firewall — TCP: $tcp_ports  UDP: ${udp_ports:-none}"
        return 0
    fi

    # Determine which firewall tool to use
    if [ "$OS_FAMILY" = "debian" ]; then
        # ufw
        pkg_install_if_missing ufw
        ufw --force reset
        ufw default deny incoming
        ufw default allow outgoing
        for p in $tcp_ports; do _open_ufw "$p" tcp; done
        for p in $udp_ports; do _open_ufw "$p" udp; done
        echo y | ufw enable
        ufw reload

    elif [ "$OS_FAMILY" = "rhel" ] && has_systemd; then
        # firewalld
        pkg_install_if_missing firewalld
        service_enable_start firewalld
        firewall-cmd --set-default-zone=drop
        # Always allow established connections
        firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="0.0.0.0/0" accept' 2>/dev/null || true
        for p in $tcp_ports; do _open_firewalld "$p" tcp; done
        for p in $udp_ports; do _open_firewalld "$p" udp; done
        firewall-cmd --reload

    else
        # iptables fallback (Alpine, CentOS 6, minimal RHEL)
        pkg_install_if_missing iptables 2>/dev/null || true

        # Flush and set defaults
        iptables -F INPUT
        iptables -P INPUT DROP
        iptables -P OUTPUT ACCEPT
        iptables -P FORWARD ACCEPT

        # Allow loopback and established
        iptables -A INPUT -i lo -j ACCEPT
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        iptables -A INPUT -p icmp -j ACCEPT

        for p in $tcp_ports; do _open_iptables "$p" tcp; done
        for p in $udp_ports; do _open_iptables "$p" udp; done

        # Persist rules
        if [ "$OS_FAMILY" = "debian" ]; then
            pkg_install_if_missing iptables-persistent
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4
        elif [ "$OS_FAMILY" = "rhel" ]; then
            mkdir -p /etc/sysconfig
            iptables-save > /etc/sysconfig/iptables
            service_enable_start iptables 2>/dev/null || true
        elif [ "$OS_FAMILY" = "alpine" ]; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules-save
            # openrc restore script
            cat > /etc/local.d/iptables.start <<'EOF'
#!/bin/sh
iptables-restore < /etc/iptables/rules-save
EOF
            chmod +x /etc/local.d/iptables.start
            rc-update add local default 2>/dev/null || true
        fi
    fi

    log_info "Firewall configured. Open TCP: $tcp_ports"
    [ -n "$udp_ports" ] && log_info "Open UDP: $udp_ports"
}
