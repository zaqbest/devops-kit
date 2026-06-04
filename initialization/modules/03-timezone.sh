#!/usr/bin/env bash
# Module 03: Configure system timezone
PHASE_KEY="TIMEZONE_SET"

main() {
    [ "${TIMEZONE_SET:-0}" = "1" ] && { log_info "Timezone already configured, skipping."; return 0; }

    local tz="${TIMEZONE:-UTC}"
    log_info "Setting timezone: $tz"

    if ! [ -f "/usr/share/zoneinfo/$tz" ]; then
        log_warn "Timezone file not found: /usr/share/zoneinfo/$tz — installing tzdata..."
        case "$OS_FAMILY" in
            debian) pkg_install_if_missing tzdata ;;
            rhel)   pkg_install_if_missing tzdata ;;
            alpine) pkg_install_if_missing tzdata ;;
        esac
    fi

    if command -v timedatectl &>/dev/null; then
        timedatectl set-timezone "$tz"
    else
        ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
        echo "$tz" > /etc/timezone
        # CentOS/RHEL legacy
        if [ -f /etc/sysconfig/clock ]; then
            sed -i "s|^ZONE=.*|ZONE=\"$tz\"|" /etc/sysconfig/clock
        fi
    fi

    log_info "Timezone set to: $tz ($(date))"
}
