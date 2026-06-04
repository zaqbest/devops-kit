#!/usr/bin/env bash
# Module 12: Print initialization summary report
# (no PHASE_KEY — always runs)

main() {
    local sep="──────────────────────────────────────────"
    banner "devops-kit Initialization Complete"

    echo ""
    printf "  %-24s %s\n" "Hostname:"        "$(hostname -f 2>/dev/null || hostname)"
    printf "  %-24s %s\n" "OS:"              "$OS_PRETTY_NAME"
    printf "  %-24s %s\n" "Timezone:"        "$(date +%Z) ($(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo unknown))"
    printf "  %-24s %s\n" "Locale:"          "${LANG:-${LOCALE:-not set}}"
    echo "  $sep"

    # Admin user
    local user="${ADMIN_USER:-devops}"
    if id "$user" &>/dev/null; then
        printf "  %-24s %s\n" "Admin user:"      "$user (sudo enabled)"
    else
        printf "  %-24s %s\n" "Admin user:"      "NOT created"
    fi

    # SSH
    printf "  %-24s %s\n" "SSH port:"        "${SSH_PORT:-22}"
    echo "  $sep"

    # Swap
    local swap_info
    swap_info=$(free -h 2>/dev/null | awk '/Swap:/ {print $2}')
    printf "  %-24s %s\n" "Swap:"            "${swap_info:-none}"
    printf "  %-24s %s\n" "vm.swappiness:"   "$(sysctl -n vm.swappiness 2>/dev/null || echo unknown)"
    echo "  $sep"

    # Firewall
    local fw_info="not detected"
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q active; then
        fw_info="ufw (active)"
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        fw_info="firewalld (active)"
    elif iptables -n -L INPUT &>/dev/null; then
        fw_info="iptables"
    fi
    printf "  %-24s %s\n" "Firewall:"        "$fw_info"
    printf "  %-24s %s\n" "Open TCP ports:"  "${UFW_ALLOWED_TCP_PORTS:-22 80 443}"
    echo "  $sep"

    # fail2ban
    if command -v fail2ban-client &>/dev/null; then
        local f2b_status
        f2b_status=$(fail2ban-client status 2>/dev/null | grep 'Number of jail' || echo "inactive")
        printf "  %-24s %s\n" "fail2ban:"        "$f2b_status"
    fi

    # Log
    printf "  %-24s %s\n" "Log file:"        "${LOG_FILE:-/var/log/devops-kit.log}"
    echo ""

    log_warn "Next steps:"
    log_warn "  1. Open a NEW terminal and test SSH as '$user' before closing this session"
    if [ "${SSH_PORT:-22}" != "22" ]; then
        log_warn "  2. SSH port changed to ${SSH_PORT} — update clients and security groups"
    fi
    log_warn "  3. Review /var/lib/devops-kit/state.env for phase status"
    echo ""
}
