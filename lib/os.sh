#!/usr/bin/env bash
# OS detection utilities — source this file, do not execute directly.

# Populated by detect_os():
OS_ID=""
OS_VERSION_ID=""
OS_VERSION_MAJOR=""
OS_PRETTY_NAME=""
OS_FAMILY=""        # debian | rhel | alpine
PKG_MGR=""          # apt | dnf | yum | apk
ARCH=""             # amd64 | arm64 | armv7 | x86
INIT_SYSTEM=""      # systemd | openrc | sysv

detect_os() {
    # 1. Parse /etc/os-release (preferred)
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_VERSION_ID="${VERSION_ID:-}"
        OS_PRETTY_NAME="${PRETTY_NAME:-$ID}"
    fi

    # 2. Fallback files for older distros
    if [ -z "$OS_ID" ]; then
        if [ -f /etc/redhat-release ]; then
            OS_ID="rhel"
            OS_VERSION_ID=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)
            OS_PRETTY_NAME=$(cat /etc/redhat-release)
        elif [ -f /etc/debian_version ]; then
            OS_ID="debian"
            OS_VERSION_ID=$(cat /etc/debian_version)
            OS_PRETTY_NAME="Debian $OS_VERSION_ID"
        elif [ -f /etc/alpine-release ]; then
            OS_ID="alpine"
            OS_VERSION_ID=$(cat /etc/alpine-release)
            OS_PRETTY_NAME="Alpine Linux $OS_VERSION_ID"
        fi
    fi

    # 3. Last resort: probe available commands
    if [ -z "$OS_ID" ]; then
        if command -v apt-get &>/dev/null; then
            OS_ID="debian"; OS_PRETTY_NAME="Debian-like"
        elif command -v dnf &>/dev/null; then
            OS_ID="rhel"; OS_PRETTY_NAME="RHEL-like"
        elif command -v yum &>/dev/null; then
            OS_ID="centos"; OS_PRETTY_NAME="CentOS-like"
        elif command -v apk &>/dev/null; then
            OS_ID="alpine"; OS_PRETTY_NAME="Alpine-like"
        fi
    fi

    # 4. Map OS_ID → OS_FAMILY
    case "$OS_ID" in
        ubuntu|debian|linuxmint|raspbian|kali|pop)
            OS_FAMILY="debian" ;;
        centos|rhel|rocky|almalinux|fedora|ol|amzn)
            OS_FAMILY="rhel" ;;
        alpine)
            OS_FAMILY="alpine" ;;
        *)
            OS_FAMILY="unknown" ;;
    esac

    # 5. Version major number
    OS_VERSION_MAJOR="${OS_VERSION_ID%%.*}"

    # 6. PKG_MGR
    case "$OS_FAMILY" in
        debian)
            PKG_MGR="apt" ;;
        rhel)
            if command -v dnf &>/dev/null; then
                PKG_MGR="dnf"
            else
                PKG_MGR="yum"
            fi
            ;;
        alpine)
            PKG_MGR="apk" ;;
        *)
            PKG_MGR="unknown" ;;
    esac

    # 7. Architecture
    case "$(uname -m)" in
        x86_64|amd64)   ARCH="amd64" ;;
        aarch64|arm64)  ARCH="arm64" ;;
        armv7l|armv7)   ARCH="armv7" ;;
        i386|i686)      ARCH="x86" ;;
        *)              ARCH="$(uname -m)" ;;
    esac

    # 8. Init system
    if [ -d /run/systemd/system ] || pidof systemd &>/dev/null; then
        INIT_SYSTEM="systemd"
    elif [ -f /sbin/openrc ] || [ -f /sbin/rc-service ]; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="sysv"
    fi

    export OS_ID OS_VERSION_ID OS_VERSION_MAJOR OS_PRETTY_NAME OS_FAMILY PKG_MGR ARCH INIT_SYSTEM
}

# Returns 0 if OS version >= MAJOR[.MINOR]
os_version_ge() {
    local req_major="$1" req_minor="${2:-0}"
    local cur_major="$OS_VERSION_MAJOR"
    local cur_minor
    cur_minor=$(echo "$OS_VERSION_ID" | cut -d. -f2)
    cur_minor="${cur_minor:-0}"

    if [ "$cur_major" -gt "$req_major" ]; then return 0
    elif [ "$cur_major" -eq "$req_major" ] && [ "$cur_minor" -ge "$req_minor" ]; then return 0
    else return 1
    fi
}

# Returns 0 if running inside a container
is_container() {
    [ -f /.dockerenv ] && return 0
    grep -qE 'docker|lxc|openvz' /proc/1/environ 2>/dev/null && return 0
    grep -qE 'lxc|docker' /proc/self/cgroup 2>/dev/null && return 0
    return 1
}

has_systemd() { [ "$INIT_SYSTEM" = "systemd" ]; }

# Enable and start a service, handling systemd vs openrc
service_enable_start() {
    local svc="$1"
    if has_systemd; then
        systemctl enable --now "$svc"
    else
        rc-update add "$svc" default
        rc-service "$svc" start
    fi
}

# Reload a service (prefer reload over restart to preserve sessions)
service_reload() {
    local svc="$1"
    if has_systemd; then
        systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc"
    else
        rc-service "$svc" reload 2>/dev/null || rc-service "$svc" restart
    fi
}
