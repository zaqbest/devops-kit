#!/usr/bin/env bash
# Module 01: System package update and common tool installation
PHASE_KEY="PACKAGES_UPDATED"

main() {
    [ "${PACKAGES_UPDATED:-0}" = "1" ] && { log_info "Packages already updated, skipping."; return 0; }

    log_info "Updating package lists..."
    pkg_update

    log_info "Upgrading installed packages..."
    pkg_upgrade

    log_info "Installing common tools..."
    local common_pkgs="curl wget git vim htop net-tools unzip tar"

    case "$OS_FAMILY" in
        debian)
            pkg_install_if_missing \
                $common_pkgs \
                apt-transport-https ca-certificates gnupg lsb-release \
                dnsutils build-essential
            # software-properties-common (add-apt-repository) is Ubuntu-only
            [ "$OS_ID" = "ubuntu" ] && pkg_install_if_missing software-properties-common
            ;;
        rhel)
            pkg_enable_epel
            pkg_install_if_missing \
                $common_pkgs \
                bind-utils openssl-devel
            ;;
        alpine)
            pkg_install_if_missing \
                $common_pkgs \
                bash sudo openssh openssl
            ;;
    esac

    log_info "Package installation complete."
}
