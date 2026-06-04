#!/usr/bin/env bash
# Package manager abstraction — source this file, do not execute directly.
# Requires lib/os.sh to be sourced first (uses PKG_MGR, OS_FAMILY).

_apt() { DEBIAN_FRONTEND=noninteractive apt-get -y -q \
    -o Dpkg::Options::="--force-confold" \
    -o Dpkg::Options::="--force-confdef" "$@"; }

pkg_update() {
    case "$PKG_MGR" in
        apt) _apt update ;;
        dnf) dnf check-update -q || true ;;  # returns 100 when updates exist
        yum) yum check-update -q || true ;;
        apk) apk update -q ;;
    esac
}

pkg_upgrade() {
    case "$PKG_MGR" in
        apt) _apt upgrade ;;
        dnf) dnf upgrade -y -q ;;
        yum) yum upgrade -y -q ;;
        apk) apk upgrade -q ;;
    esac
}

pkg_install() {
    case "$PKG_MGR" in
        apt) _apt install "$@" ;;
        dnf) dnf install -y -q "$@" ;;
        yum) yum install -y -q "$@" ;;
        apk) apk add -q "$@" ;;
    esac
}

pkg_is_installed() {
    local pkg="$1"
    case "$PKG_MGR" in
        apt) dpkg -l "$pkg" 2>/dev/null | grep -q '^ii' ;;
        dnf|yum) rpm -q "$pkg" &>/dev/null ;;
        apk) apk info -e "$pkg" &>/dev/null ;;
    esac
}

pkg_install_if_missing() {
    local pkg
    for pkg in "$@"; do
        if ! pkg_is_installed "$pkg"; then
            log_info "Installing: $pkg"
            pkg_install "$pkg"
        else
            log_info "Already installed: $pkg"
        fi
    done
}

pkg_remove() {
    case "$PKG_MGR" in
        apt) _apt purge "$@" ;;
        dnf) dnf remove -y -q "$@" ;;
        yum) yum remove -y -q "$@" ;;
        apk) apk del -q "$@" ;;
    esac
}

pkg_enable_epel() {
    [ "$OS_FAMILY" = "rhel" ] || return 0
    if [ "$OS_VERSION_MAJOR" -ge 9 ]; then
        dnf config-manager --set-enabled crb 2>/dev/null || \
            dnf config-manager --set-enabled powertools 2>/dev/null || true
        pkg_install_if_missing epel-release
    elif [ "$OS_VERSION_MAJOR" -ge 8 ]; then
        pkg_install_if_missing epel-release
        dnf config-manager --set-enabled powertools 2>/dev/null || true
    else
        # CentOS 7
        pkg_install_if_missing epel-release
    fi
}

pkg_add_repo_apt() {
    local repo_line="$1" keyserver="$2" key_id="$3"
    echo "$repo_line" | tee /etc/apt/sources.list.d/devops-kit-extra.list > /dev/null
    if [ -n "$keyserver" ] && [ -n "$key_id" ]; then
        apt-key adv --keyserver "$keyserver" --recv-keys "$key_id" 2>/dev/null || true
    fi
    pkg_update
}
